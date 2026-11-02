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

-- A function's own upvalues first, then the functions it holds, so a same-named local of a
-- nested closure cannot shadow the one the function itself uses.
local function find(fn, wanted, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  local nested = {}
  for i = 1, 200 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
    if type(value) == "function" then nested[#nested + 1] = value end
  end
  for i = 1, #nested do
    local found = find(nested[i], wanted, seen)
    if found ~= nil then return found end
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

-- A string that is exactly one of the strings in the trees (a label's whole text).
local function showsExactly(Stubs, text)
  local all = strings(Stubs.lvgl.trees, {})
  for i = 1, #all do
    if all[i] == text then return true end
  end
  return false
end

-- Every rectangle anywhere in the recorded trees.
local function rectangles(node, out, seen)
  seen = seen or {}
  if seen[node] then return out end
  seen[node] = true
  if node.type == "rectangle" then out[#out + 1] = node end
  for _, v in pairs(node) do
    if type(v) == "table" then rectangles(v, out, seen) end
  end
  return out
end

-- The progress bar of the notice (ui/loading_overlay.lua): a 16 px track, and inside it, 2 px in, a
-- 12 px fill whose width is the progress. A fill of width 0 is left out, so no fill reads as 0.
-- Returns nil when no track is drawn at all.
local function barFill(Stubs)
  local all = rectangles(Stubs.lvgl.trees, {})
  for i = 1, #all do
    local track = all[i]
    if track.h == 16 and type(track.w) == "number" then
      for j = 1, #all do
        local fill = all[j]
        if fill.h == 12 and fill.x == track.x + 2 and fill.y == track.y + 2 then
          return fill.w, track.w
        end
      end
      return 0, track.w
    end
  end
  return nil
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

-- The notice asks the tool's translator for its text on every build. A distinctive answer for the
-- save text proves that the message on screen is the translated one, not a fallback literal.
local SAVE_TEXT = "<translated save text>"
local translator = assert(state.i18n and state.i18n.t, "home translator missing")
state.i18n = { t = function(key, ...)
  if key == "app.saving_settings" then return SAVE_TEXT end
  return translator(key, ...)
end }

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
check(showsExactly(Stubs, SAVE_TEXT), "write phase shows the translated save text")
local writeFill, trackW = barFill(Stubs)
check(writeFill ~= nil and writeFill > 0, "write phase fills the bar", writeFill)

-- The EEPROM commit (the pipeline reports no label there): the same text.
draw({ phase = "commit", label = nil, done = 2, total = 3, fraction = 2 / 3 })
check(showsExactly(Stubs, SAVE_TEXT), "commit phase shows the translated save text")
-- Without the step's name, the bar is what tells the pilot how far the save has come.
local commitFill = barFill(Stubs)
check(writeFill and commitFill and commitFill > writeFill and commitFill < trackW,
  "the bar fills further at the commit than at the first write", tostring(writeFill) .. " -> " .. tostring(commitFill))

-- Control: a phase with a text of its own still shows it, so the trees are being read.
draw({ phase = "reboot", label = nil, done = 3, total = 3, fraction = 1, indeterminate = true })
check(shows(Stubs, "app.save.rebooting"), "reboot phase shows its own text (control)")

-- Control: the reader finds a string that is in a tree.
draw({ phase = "write", label = LABEL, done = 1, total = 3, fraction = 1 / 3, terminal = true,
  status = "failed", result = {} })
check(shows(Stubs, "app.save.failed_message"), "a failed save shows its own text (control)")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
