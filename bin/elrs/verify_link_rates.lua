-- Run from the repository root with desktop Lua 5.3:
--   lua5.3 bin/elrs/verify_link_rates.lua [path/to/elrslink_task.lua]
-- Like verify_offline_theme_settings.lua, reach production locals through debug upvalues.
-- Only module loading, logging and the MSP queue are stubbed; no hardware/timing claim.
local queued = {}
_G.rfsuite = { session = {}, Log = { emit = function() end } }
_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
_G.loadScript = function(path)
    return function()
        if string.match(path, "tasks/msp/runtime.lua$") then
            return { getState = function()
                return { queue = { add = function(_, item) queued[#queued + 1] = item end } }
            end }
        elseif string.match(path, "tasks/msp/api/telemetry_config.lua$") then
            return { writeCommand = 0x1234 }
        end
    end
end
local task = assert(loadfile(arg[1] or "src/rfsuite/app/pages/tools/diagnostics/elrs_link/elrslink_task.lua"))()
local function upvalue(fn, name, ...)
    for i = 1, 100 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then
            if select("#", ...) > 0 then debug.setupvalue(fn, i, ...) end
            return value
        end
    end
    error("missing production upvalue: " .. name)
end
local finalize = upvalue(task.wakeup, "finalize")
local parseRate = upvalue(finalize, "parseRateFromLabel")
local resolveRatio = upvalue(finalize, "resolveEffectiveRatio")
local parseRatio = upvalue(finalize, "parseRatioLabel")
local syncToModule = upvalue(finalize, "syncRotorflightToElrs")
local findRateTarget = upvalue(syncToModule, "findRateTarget")
local checks, failures = 0, 0
local function equal(actual, expected, label)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        print("FAIL: " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
    end
end

local labels = {
    { "50Hz(-115dBm)", 50 }, { "100Hz Full(-112dBm)", 100 },
    { "150Hz(-112dBm)", 150 }, { "250Hz(-108dBm)", 250 },
    { "333Hz Full(-105dBm)", 333 }, { "500Hz(-105dBm)", 500 },
    { "D250(-104dBm)", 1000 }, { "D500(-104dBm)", 1000 },
    { "F500(-104dBm)", 500 }, { "F1000(-104dBm)", 1000 },
    { "DK250(-103dBm)", 1000 }, { "DK500(-103dBm)", 1000 },
    { "K1000(-103dBm)", 1000 }, { "D50Hz(-112dBm)", 200 },
    { "K1000 Full(-101dBm)", 1000 }, { "25Hz", 25 }, { "200Hz Full", 200 },
    { "500Hz", 500 }, { "F1000", 1000 }, { "K1000", 1000 },
    { "333Hz Full", 333 }, { "50Hz", 50 }, { "100Hz Full", 100 },
    { "K1000 Full", 1000 },
    { "D250", 1000 }, { "D500", 1000 }, { "DK250", 1000 }, { "DK500", 1000 }, { "D50Hz", 200 },
    { " dK500(-103dBm)", 1000 }, { "d50HZ(-112dBm)", 200 },
    { "D500-extra", 1000 }, { "D500X", 500 }, { "D125(-100dBm)", 125 },
    { "DK333(-100dBm)", 333 }, { "", nil }, { "2.4GHz", nil },
}
for _, item in ipairs(labels) do equal(parseRate(item[1]), item[2], item[1]) end
equal(parseRate(nil), nil, "absent label")
equal(parseRate(500), nil, "non-string label")
print("Rate labels: " .. checks .. " checks")

local explicit, kind = parseRatio("Std")
for _, item in ipairs({ { "D500", 128 }, { "D250", 128 }, { "D50Hz", 64 } }) do
    equal(resolveRatio(parseRate(item[1]), kind, explicit), item[2], item[1] .. " Std ratio")
end

local options = {}
for i = 1, 10 do options[i] = labels[i][1] end
local field = { id = 1, name = "Packet Rate", options = options, selectedIndex = 7 }
local index, label = findRateTarget(field, 1000)
equal(index, 7, "keep D500 index")
equal(label, "D500(-104dBm)", "keep D500 label")
field.selectedIndex = 5
index, label = findRateTarget(field, 1000)
equal(index, 9, "500Hz -> 1000 keeps original F1000 choice")
equal(label, "F1000(-104dBm)", "500Hz -> F1000 label")

-- Check the session handover and actual FC payload without changing the production exports.
for _, item in ipairs({ { "D500(-104dBm)", 1000, 128 }, { "D50Hz(-112dBm)", 200, 64 } }) do
    task.reset()
    queued = {}
    local buffer = { 11, 22, 33, 44, 55, 66, 77, 0, 0, 0, 0, 0, 99 }
    rfsuite.session = {
        crsfTelemetryConfig = { mode = 1, linkRate = 500, linkRatio = 128 },
        telemetryConfigBuffer = buffer,
    }
    upvalue(finalize, "moduleRateLabel", item[1])
    upvalue(finalize, "moduleRatioLabel", "Std")
    upvalue(finalize, "manualSyncMode", task.MODE_ELRS_TO_ROTORFLIGHT)
    finalize()
    equal(rfsuite.session.elrsLinkConfig.packetRate, item[2], item[1] .. " session air rate")
    equal(rfsuite.session.elrsLinkConfig.packetRateLabel, item[1], "session preserves module label")
    equal(rfsuite.session.elrsLinkConfig.telemetryRatio, item[3], "session Std ratio")
    equal(#queued, 1, "FC write positive control")
    local payload = assert(queued[1]).payload
    equal(payload[8], 1, "FC custom mode")
    equal(payload[9] + 256 * payload[10], item[2], "FC air rate")
    equal(payload[11] + 256 * payload[12], item[3], "FC Std ratio")
    equal(payload[1], buffer[1], "FC payload prefix preserved")
    equal(payload[13], buffer[13], "FC payload suffix preserved")
    equal(buffer[9], 0, "source buffer preserved")
end

-- A matching D500 must queue no rate write; 500Hz must queue F1000 as a positive control.
for _, item in ipairs({ { 7, 0 }, { 5, 1 } }) do
    task.reset()
    field.selectedIndex = item[1]
    upvalue(syncToModule, "rateField", field)
    upvalue(syncToModule, "ratioField", { id = 2, options = { "1:128" }, selectedIndex = 0 })
    syncToModule({ linkRate = 1000, linkRatio = 128 })
    equal(upvalue(syncToModule, "pendingWriteCount"), item[2], "module rate write count")
    if item[2] == 1 then
        equal(upvalue(syncToModule, "pendingWrites")[1].value, 9, "queued F1000 index")
    end
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
