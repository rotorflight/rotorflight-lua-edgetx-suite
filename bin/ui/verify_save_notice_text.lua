-- The save notice says what the save is doing in words the pilot can read, never a step's label.
--   lua5.3 bin/ui/verify_save_notice_text.lua
--   lua5.3 bin/ui/verify_save_notice_text.lua --source-root <other-checkout>
-- Loads the real ui/home.lua on the accounting stubs, lets it start, then hands its save pipeline
-- a progress report per phase and builds the screen with home's own buildUI. Every string in
-- the recorded LVGL trees is searched. A step label is an internal identifier (the pages pass the
-- MSP command's name), so it must not appear in any tree; the phases that have a text of their
-- own must still show it, which is the control that the trees are read at all.
-- No pixels, hardware or timing are measured. Exit 0 green, 1 failed checks, 2 bad CLI.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]ui$") or (dir .. "/../..") end
end
local root = ROOT
if #arg == 2 and arg[1] == "--source-root" then
  root = arg[2]
elseif #arg > 0 then
  io.stderr:write("usage: lua5.3 bin/ui/verify_save_notice_text.lua [--source-root <checkout>]\n")
  os.exit(2)
end

local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local function find(fn, wanted, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  for i = 1, 200 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
    if type(value) == "function" then
      local found = find(value, wanted, seen)
      if found ~= nil then return found end
    end
  end
end

-- Every string anywhere in the recorded trees, keys excluded.
local function strings(node, out, seen)
  seen = seen or {}
  if seen[node] then return out end
  seen[node] = true
  for _, v in pairs(node) do
    if type(v) == "string" then
      out[#out + 1] = v
    elseif type(v) == "table" then
      strings(v, out, seen)
    end
  end
  return out
end

local function shows(Stubs, needle)
  local all = strings(Stubs.lvgl.trees, {})
  for i = 1, #all do
    if string.find(all[i], needle, 1, true) then return true end
  end
  return false
end

local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(root); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()

local Home = assert(loadfile(root .. "/src/rfsuite/ui/home.lua"))()
Home.init({})
for _ = 1, 40 do Stubs.tick(); Home.run(0) end

local state = assert(find(Home.run, "state"), "home state missing")
local M = assert(find(Home.run, "M"), "home module table missing")
local buildUI = assert(M.buildUI, "home buildUI missing")
local pipeline = assert(find(Home.run, "SavePipeline"), "home save pipeline missing")
state.initialLoad = false

local LABEL = "MSP_SET_PID_PROFILE"
local current = nil
pipeline.getProgress = function() return current end

local function draw(progress)
  current = progress
  Stubs.lvgl.trees = {}
  buildUI()
  current = nil
end

-- The write phase: the step being written carries its label.
draw({ phase = "write", label = LABEL, done = 1, total = 3, fraction = 1 / 3 })
check(#Stubs.lvgl.trees > 0, "write phase builds a notice")
check(not shows(Stubs, LABEL), "write phase keeps the step label off the screen", LABEL)
check(shows(Stubs, "Applying settings") or shows(Stubs, "app.saving_settings"),
  "write phase shows the translated save text")

-- The EEPROM commit: no label, the same text.
draw({ phase = "commit", label = nil, done = 3, total = 3, fraction = 1 })
check(shows(Stubs, "Applying settings") or shows(Stubs, "app.saving_settings"),
  "commit phase shows the translated save text")

-- Control: a phase with a text of its own still shows it, so the trees are being read.
draw({ phase = "reboot", label = nil, done = 3, total = 3, fraction = 1, indeterminate = true })
check(shows(Stubs, "app.save.rebooting"), "reboot phase shows its own text (control)")

-- Control: the reader finds a string that is in a tree.
draw({ phase = "write", label = LABEL, done = 1, total = 3, fraction = 1 / 3, terminal = true,
  status = "failed", result = {} })
check(shows(Stubs, "app.save.failed_message"), "a failed save shows its own text (control)")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
