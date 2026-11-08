-- Run the real YGE page with recorded MSP requests and edited simulator replies.
-- Invoke from the repository root: lua bin/esc/verify_yge_flag_bit3.lua
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/setup/esc_motors/esc_tools/escmfg/yge/"
local function newPage()
  local apiPath = "tasks/msp/api/esc_parameters_yge.lua"
  local api = assert(loadfile("src/rfsuite/" .. apiPath))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local fields, combos, notice = {}, {}, nil
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end
    },
    ["ui/controls.lua"] = {
      appendNumberField = function(_, _, _, _, label, options)
        fields[label] = options
        return 40
      end,
      appendComboSelect = function(_, _, _, _, label, _, value, set)
        combos[label] = { value = value, set = set }
        return 40
      end
    },
    ["ui/loading_overlay.lua"] = {
      appendNotice = function(_, options) notice = options end
    },
    ["ui/confirm_dialog.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
    [apiPath] = api,
    [base .. "init.lua"] = assert(loadfile("src/rfsuite/" .. base .. "init.lua"))(),
    ["app/pages/setup/esc_motors/esc_tools/esc_current_limit.lua"] = {
      remember = function() end,
      forget = function() end
    }
  }
  _G.rfsuite = { palette = {}, session = {} }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  function loadScript(path)
    local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
  local page = assert(loadfile("src/rfsuite/" .. base .. "page.lua"))()
  local ctx = { children = {}, x = 0, y = 0, w = 480, h = 320,
    requestRebuild = function() end }
  page.wakeup(ctx)
  local function build()
    page.build(ctx)
    assert(notice, "initial safety notice missing").press()
    page.build(ctx)
  end
  return { page = page, api = api, queue = queue, ctx = ctx,
    fields = fields, combos = combos, build = build }
end

local scenarios = {
  { name = "bit 3 set, BEC lowered", flags = 0xAA, initialVoltage = 120, voltage = 84,
    controls = 0x05, escType = 5712, maxVoltage = 120 },
  { name = "bit 3 clear, BEC raised to 12 V", flags = 0x55, initialVoltage = 84, voltage = 120,
    controls = 0x02, escType = 5712, maxVoltage = 120 },
  { name = "8.4 V model, bit 3 set", flags = 0xAE, initialVoltage = 55, voltage = 84,
    controls = 0x01, escType = 848, maxVoltage = 84 },
  { name = "8.4 V model, bit 3 clear", flags = 0x51, initialVoltage = 55, voltage = 84,
    controls = 0x06, escType = 848, maxVoltage = 84 }
}

for _, scenario in ipairs(scenarios) do
  local function eq(actual, expected, label)
    equal(actual, expected, scenario.name .. ": " .. label)
  end
  local ok, err = pcall(function()
    local h = newPage()
    local reply = {}
    for i, value in ipairs(h.api.simulatorResponse) do reply[i] = value end
    -- One-based offsets in the 66-byte block, including its two-byte MSP header.
    reply[7], reply[8] = scenario.initialVoltage, 0
    reply[25], reply[26] = scenario.escType & 0xFF, (scenario.escType >> 8) & 0xFF
    reply[55] = scenario.flags
    eq(#reply, 66, "fixture length")
    local read = assert(h.queue.entries[1], "initial read missing")
    eq(read.command, h.api.command, "initial read command")
    read.processReply(read, reply)
    h.build()

    local bec = assert(h.fields["BEC Voltage"], "BEC Voltage field missing")
    eq(bec.get(), scenario.initialVoltage, "BEC voltage read from reply")
    eq(bec.min, 55, "BEC minimum unchanged")
    eq(bec.max, scenario.maxVoltage, "BEC maximum follows model, not bit 3")
    eq(bec.step, 1, "BEC step unchanged")
    eq(scenario.voltage >= bec.min and scenario.voltage <= bec.max, true, "edit is within range")
    bec.set(scenario.voltage)
    eq(bec.get(), scenario.voltage, "BEC setter updates voltage")
    eq(h.page.hasUnsavedChanges(), true, "BEC setter marks page dirty")

    -- Exercise each real control callback, with all three bits changed in both directions.
    for bit, label in ipairs({ "Direction", "F3C Auto", "Keep mAh" }) do
      local control = assert(h.combos[label], label .. " control missing")
      eq(control.value, (scenario.flags >> (bit - 1)) & 1, label .. " read from flags")
      control.set((scenario.controls >> (bit - 1)) & 1)
    end
    eq(h.page.onSave(h.ctx), true, "save accepted after read")
    eq(#h.queue.entries, 2, "one write queued after initial read")
    local write = assert(h.queue.entries[2], "write missing")
    eq(write.command, h.api.writeCommand, "save command")
    eq(write.isWrite, true, "save classified as write")
    eq(#write.payload, #reply, "write keeps block length")
    eq(write.payload[7] | (write.payload[8] << 8), scenario.voltage, "written BEC voltage")
    local flags = assert(write.payload[55], "written flags byte missing")
    eq((flags >> 3) & 1, (scenario.flags >> 3) & 1, "bit 3 preserved")
    eq(flags & 0xF0, scenario.flags & 0xF0, "bits 4..7 preserved")
    for bit = 0, 2 do
      eq((flags >> bit) & 1, (scenario.controls >> bit) & 1, "bit " .. bit .. " follows control")
    end
    eq(flags, (scenario.flags & 0xF8) | scenario.controls, "complete flags byte")
  end)
  if not ok then
    failures = failures + 1
    print("FAIL " .. scenario.name .. ": " .. tostring(err))
  end
end

if failures > 0 then
  print("YGE flags bit 3: " .. failures .. " failures, " .. checks .. " assertions checked")
  os.exit(1)
end
print("YGE flags bit 3: " .. checks .. " assertions passed")
