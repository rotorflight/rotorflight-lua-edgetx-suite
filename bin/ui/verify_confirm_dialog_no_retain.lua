-- Run the real confirm dialog with LVGL callbacks retained for the life of the state.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local registry = {}
_G.rfsuite = {}
_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
lvgl = { confirm = function(options) registry[#registry + 1] = options end }
function loadScript(path)
  assert(path == "/SCRIPTS/RFSUITE/core/lib/log.lua", "unexpected module: " .. tostring(path))
  return function() return { emit = function() end } end
end
local dialog = assert(loadfile("src/rfsuite/ui/confirm_dialog.lua"))()
local function newDialog()
  local payload = {}
  local weak = setmetatable({ [payload] = true }, { __mode = "k" })
  local calls = { confirm = 0, cancel = 0 }
  local function handler(which)
    return function() payload.answer = which; calls[which] = calls[which] + 1 end
  end
  equal(dialog.show({ onConfirm = handler("confirm"), onCancel = handler("cancel") }), true, "dialog shown")
  return registry[#registry], calls, weak
end
local function collected(weak)
  collectgarbage("collect")
  collectgarbage("collect")
  return next(weak) == nil
end

for _, answer in ipairs({ "confirm", "cancel" }) do
  local callbacks, calls, weak = newDialog()
  equal(collected(weak), false, answer .. " pending handler retained")
  callbacks[answer]()
  callbacks.confirm()
  callbacks.cancel()
  equal(calls.confirm, answer == "confirm" and 1 or 0, answer .. " confirm count")
  equal(calls.cancel, answer == "cancel" and 1 or 0, answer .. " cancel count")
  equal(collected(weak), true, answer .. " answered handler released")
end

local callbacks, calls, weak = newDialog()
equal(collected(weak), false, "unanswered handler retained")
-- Match tool_host.finish: drop all pending handlers without loading a module.
local slot = _G.rfsuite.confirmDialogSlot; if slot then slot.pending = {} end
equal(collected(weak), true, "closed tool handler released")
equal(pcall(callbacks.confirm), true, "late confirm does not raise")
equal(pcall(callbacks.cancel), true, "late cancel does not raise")
equal(calls.confirm, 0, "late confirm runs nothing")
equal(calls.cancel, 0, "late cancel runs nothing")

local first, firstCalls = newDialog()
local second, secondCalls = newDialog()
first.confirm()
equal(firstCalls.confirm, 1, "first stacked dialog answered")
equal(secondCalls.confirm + secondCalls.cancel, 0, "second stacked dialog still pending")
second.cancel()
first.confirm()
first.cancel()
second.confirm()
second.cancel()
equal(firstCalls.confirm, 1, "first stacked confirm runs once")
equal(firstCalls.cancel, 0, "first stacked cancel never runs")
equal(secondCalls.confirm, 0, "second stacked confirm never runs")
equal(secondCalls.cancel, 1, "second stacked cancel runs once")

print("Confirm dialog no retain: " .. checks .. " assertions, " .. failures .. " failures")
if failures > 0 then os.exit(1) end
