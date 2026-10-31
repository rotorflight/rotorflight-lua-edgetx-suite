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
local overlay = nil

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
    end,
    -- The real close hook: it releases ui.runtime, which is how a later visit tells its
    -- own replies from an earlier one's.
    resetPageState = function(...)
      return assert(loadfile("src/rfsuite/app/pages/settings/common.lua"))().resetPageState(...)
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
    append = function(_, options) overlay = options end,
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
  overlay = nil
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

scenario("switch back to ESC 1", function()
  -- Restore the same target within one visit; leaving the page clears its cache.
  assert(#pending == 0, "switch-back requires a drained queue")
  selectTarget(0)
  render(page)
  deliverRead(page, refused)
  equal(rowValue("ESC Target"), 0, "target control switches back to ESC 1")
  equal(header, "Bluejay Configurator - ESC1-MODEL", "same-target model is restored")
  equal(firmware, "ESC1-FIRMWARE", "same-target firmware is restored")
  equal(version, "ESC1-VERSION", "same-target version is restored")
  equal(rowValue("Motor Direction"), 2, "same-target direction is restored")
  equal(rowValue("Min Startup Power"), 1110, "same-target numeric config is restored")
  equal(rowValue("Max Startup Power"), 1200, "same-target maximum startup power is restored")
  equal(rowValue("PWM Frequency"), 48, "same-target PWM frequency is restored")
  assertSaveRefused(page, "restored ESC 1")
  equal(readReplies, 3, "one good read and two refused reads are delivered")
  equal(refusedReplies, 2, "two replies are refused by the parser")
end)

-- Advance reset/select and post-save writes, but leave the parameter read pending.
local function waitForRead(page)
  for _ = 1, 40 do
    while #pending > 0 do
      local message = pending[1]
      if message.command == 217 then return message end
      assert(message.command == 218 or message.command == 245, "unexpected queued command")
      table.remove(pending, 1)
      message.processReply(message, {})
    end
    page.wakeup(ctx)
    ticks = ticks + 50
  end
  error("no parameter read was queued")
end

local function switchWithReadPending()
  -- Each route starts independently, including when a previous assertion failed.
  pending = {}
  _G.rfsuite.session = { esc4WayMotorCount = 2 }
  local activePage = assert(loadfile(pagePath))()
  render(activePage)
  deliverRead(activePage, good)
  equal(rowValue("Motor Direction"), 2, "in-flight route starts with ESC 1's good read")
  rows["Motor Direction"].set(1)
  equal(activePage.onSave(ctx), true, "ESC 1 save starts the post-save read cycle")
  local lateRead = waitForRead(activePage)
  render(activePage)
  equal(rowValue("ESC Target"), 0, "target control is available during the auto read")
  selectTarget(1)
  render(activePage)
  equal(table.remove(pending, 1), lateRead, "ESC 1 read is still pending at the switch")
  return activePage, lateRead
end

local function assertEsc2Defaults(label)
  equal(overlay, nil, label .. " finishes loading")
  equal(rowValue("ESC Target"), 1, label .. " keeps ESC 2 selected")
  equal(header, "Bluejay Configurator", label .. " has no ESC 1 model")
  equal(firmware, nil, label .. " has no ESC 1 firmware")
  equal(version, nil, label .. " has no ESC 1 version")
  equal(rowValue("Motor Direction"), 0, label .. " keeps the initial direction")
  equal(rowValue("Rampup Start Power"), 0, label .. " keeps the initial layout and rampup power")
  equal(rowValue("Min Startup Power"), 1000, label .. " keeps the initial startup power")
  equal(rowValue("Max Startup Power"), 1300, label .. " keeps the initial maximum startup power")
  equal(rowValue("PWM Frequency"), 0, label .. " keeps the initial PWM frequency")
end

scenario("late ESC 1 reply before ESC 2 read", function()
  local activePage, lateRead = switchWithReadPending()
  local cached = _G.rfsuite.session.setup_esc_motors_esc_tools_bluejay
  lateRead.processReply(lateRead, good)
  render(activePage)
  equal(overlay and overlay.title, "Loading", "late reply keeps ESC 2 loading")
  equal(overlay and overlay.progress, 0, "late reply preserves ESC 2 progress")
  equal(header, nil, "late reply does not display ESC 1's model in the window")
  equal(firmware, nil, "late reply does not display ESC 1's firmware in the window")
  equal(version, nil, "late reply does not display ESC 1's version in the window")
  equal(rows["Motor Direction"], nil, "late reply does not display ESC 1's values in the window")
  equal(_G.rfsuite.session.setup_esc_motors_esc_tools_bluejay, cached,
    "late reply leaves the session cache untouched")
  assertSaveRefused(activePage, "ESC 2 in the late-reply window")
end)

scenario("ESC 2 refuses its read after a late ESC 1 reply", function()
  local activePage, lateRead = switchWithReadPending()
  lateRead.processReply(lateRead, good)
  local before = refusedReplies
  deliverRead(activePage, refused)
  equal(refusedReplies, before + 1, "ESC 2's own reply reaches the parser and is refused")
  assertEsc2Defaults("ESC 2 after the refused read")
  assertSaveRefused(activePage, "ESC 2 after the refused read")
end)

scenario("stale handlers preserve ESC 2's pending read", function()
  -- Exercise both stale handlers with the new target's actual read already queued.
  for _, handler in ipairs({ "processReply", "errorHandler" }) do
    local activePage, lateRead = switchWithReadPending()
    local currentRead = waitForRead(activePage)
    lateRead[handler](lateRead, good)
    render(activePage)
    equal(overlay and overlay.title, "Loading", handler .. " keeps the current read loading")
    equal(overlay and overlay.progress, 0, handler .. " keeps the current progress")
    local queued = #pending
    activePage.onReload(ctx)
    equal(#pending, queued, handler .. " keeps readPending so reload queues no duplicate")
    equal(table.remove(pending, 1), currentRead, handler .. " leaves the current read queued")
    currentRead.processReply(currentRead, refused)
    render(activePage)
    assertEsc2Defaults(handler .. " followed by the current reply")
    assertSaveRefused(activePage, handler .. " followed by the current reply")
  end
end)

scenario("a read reply from before the page closed is ignored by the next visit", function()
  -- The host closes the page while its read is still queued, then opens it again. The page
  -- module survives its close, so the old reply finds the new visit's state.
  pending = {}
  _G.rfsuite.session = { esc4WayMotorCount = 2 }
  local activePage = assert(loadfile(pagePath))()
  render(activePage)
  local oldRead = waitForRead(activePage)
  table.remove(pending, 1)
  activePage.onClose()
  pending = {}
  render(activePage)
  activePage.wakeup(ctx)
  oldRead.processReply(oldRead, good)
  render(activePage)
  equal(header, nil, "the old reply does not show its model in the new visit")
  equal(rows["Motor Direction"], nil, "the old reply does not show its values in the new visit")
  equal(_G.rfsuite.session.setup_esc_motors_esc_tools_bluejay, nil,
    "the old reply does not fill the new visit's session cache")
  oldRead.errorHandler(oldRead, "late")
  render(activePage)
  equal(overlay and overlay.title, "Loading", "the old error leaves the new visit loading")
  deliverRead(activePage, refused)
  equal(header, "Bluejay Configurator", "the new visit's own refused read shows no model")
  assertSaveRefused(activePage, "new visit after a late reply")
end)

print("Bluejay target: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
