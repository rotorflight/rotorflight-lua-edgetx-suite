-- The in-flight tuning surfaces draw in the suite's colour scheme, the one the pilot chose on
-- Settings > General > Appearance (`general.color_scheme`), and in nothing else.
--
-- Every surface is built in the light scheme (also what an unset or unknown value reads as) and in
-- the dark one, and every colour on every node -- a fill, a text, an outline, a reactive colour
-- called back -- has to be one of that scheme's values. On top of that, the rules the surfaces
-- share: the page behind everything, the header strip with its rule in light only, the red close
-- box with its glyph on it, one accented primary on the ground, Restore all named in the error
-- colour on a cell like the others, and no box round the ground status.
--
-- lcd.RGB is stubbed as the identity on 0xRRGGBB, so a colour is its own number here.
_G.lcd = {RGB = function(rgb, g, b) if g ~= nil then return rgb * 65536 + g * 256 + b end return rgb end}
debug.getmetatable("").__index = nil
local sourceRoot = arg[1] or "src"
local checked, failures = 0, {}
local function check(value, message)
  checked = checked + 1
  if not value then failures[#failures + 1] = message end
end
getTime = function() return 1000 end
getRSSI = function() return 100 end
local fakePrime = {
  boardOnLink = function() return "board-a" end,
  start = function() end,
  isRunning = function() return false end,
  groundRefusal = function() return nil end,
  delta = function() return {{scope = "pid", profile = 1, group = 1, name = "Roll P-gain", old = 70, new = 72}} end,
}
local cache = {}
rfsuite = {session = {mcu_id = "mcu-a", apiVersion = {12, 0, 9}, modelPreferences = {inflight = {}}}}
local pathsChunk = loadfile(sourceRoot .. "/rfsuite/lib/paths.lua")
rfsuite.paths = pathsChunk and pathsChunk() or nil
rfsuite.clearModule = function(path) cache[path] = nil end
rfsuite.require = function(path)
  if path == "lib/log.lua" then return {wanted = function() return false end, emit = function() end} end
  if path == "lib/sensors.lua" then return {getValue = function() return 0 end} end
  if path == "tasks/msp/runtime.lua" then
    return {getState = function() return {queue = {add = function() end, clear = function() end}} end}
  end
  if path == "widgets/dashboard/inflight/prime.lua" then return fakePrime end
  if not cache[path] then cache[path] = assert(loadfile(sourceRoot .. "/rfsuite/" .. path))() end
  return cache[path]
end
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE, LEFT, RIGHT, CENTER, VCENTER = 1, 2, 3, 4, 0, 1, 2, 4
BLACK, WHITE, BLUE, RED, GREEN, YELLOW = 0, 1, 2, 3, 4, 5
lvgl = {SCROLL_VER = 12}
local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
local Setup = rfsuite.require("widgets/dashboard/inflight/setup.lua")
local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
local Schemes = rfsuite.require("lib/color_schemes.lua")

local function translate(_, fallback) return fallback end

local function view(scheme, size, inflight, armed)
  local drive = Drive.newDrive(nil, Setup.settings({inflight = {enabled = true}}, {}))
  drive.open, drive.phase, drive._checkResult, drive._checkedAt = true, inflight.phase, "ok", 1000
  local widget = {_inflight = drive, i18n = {t = translate}, zone = {w = size[1], h = size[2]},
    preferences = {general = {color_scheme = scheme}},
    state = {armed = armed == true, armedSeen = true, fblConnected = true, inflight = inflight}}
  return widget, drive
end

local function value(field)
  if type(field) == "function" then return field() end
  return field
end

-- Every colour a node or one of its children carries, with where it was found.
local function colours(nodes, out, path)
  for index, node in ipairs(nodes) do
    for _, key in ipairs({"color", "textColor"}) do
      local colour = value(node[key])
      if colour ~= nil then out[#out + 1] = {colour = colour, node = node, where = path .. index .. "." .. key} end
    end
    if type(node.children) == "table" then colours(node.children, out, path .. index .. ">") end
  end
  return out
end

local function schemeValues(name)
  local set = {}
  for _, rgb in pairs(Schemes.colors(name)) do set[rgb] = true end
  return set
end

local function labelled(nodes, text)
  for index, node in ipairs(nodes) do
    if node.type == "label" and value(node.text) == text and index > 1 and nodes[index - 1].type == "button" then
      return nodes[index - 1], node
    end
  end
end

local GROUP = {name = "Roll", entries = {{id = 1, name = "P-gain"}, {id = 2, name = "I-gain"}}}
local ROWS = {{name = "P-gain", valueText = "70", differenceText = "+2"}, {name = "I-gain", valueText = "90", differenceText = ""}}
local SURFACES = {
  {name = "ground", inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36,
    prime = {phase = "done"}, boundsCount = 2}},
  {name = "ground, empty board", inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 0,
    prime = {phase = "done"}}},
  {name = "live list", armed = true, inflight = {phase = "live", live = true, profileText = "PID 1 / RTE 1",
    groups = {GROUP}, group = 1, groupRows = ROWS, entry = 1}},
  {name = "live value", armed = true, inflight = {phase = "live", live = true, profileText = "PID 1 / RTE 1",
    groups = {GROUP}, group = 1, groupRows = ROWS, entry = 1, valueMode = true, activeName = "P-gain",
    activeValueText = "72", activeComparison = "70 -> 72"}},
  {name = "live paused", armed = true, inflight = {phase = "live", live = true, profileRefusal = "pid_unread",
    groups = {GROUP}, group = 1, groupRows = ROWS, entry = 1}},
  {name = "after landing", inflight = {phase = "post", setupVerdict = "ok", setSource = "board", cellCount = 36}},
  {name = "restore question", inflight = {phase = "ground", setSource = "board", cellCount = 36},
    drive = function(drive) drive.restoreConfirm = {all = true} end},
  {name = "after-landing actions", inflight = {phase = "post", setSource = "board", cellCount = 36},
    drive = function(drive) drive.postActionsOpen = {kind = "pid", index = 1} end},
  {name = "group picker", armed = true, inflight = {phase = "live", live = true, profileText = "PID 1 / RTE 1",
    groups = {GROUP, {name = "Pitch", entries = {{id = 3, name = "P-gain"}}}}, group = 1, groupRows = ROWS, entry = 1,
    groupPicker = true}},
  {name = "parameter choice", inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36,
    prime = {phase = "done"}},
    drive = function(drive)
      drive.sessionPickerOpen, drive.allGroups = true, {GROUP}
      drive.sessionPick = {page = 1, wanted = {[1] = true}}
    end},
  {name = "ground, reading", inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36,
    prime = {phase = "done"}},
    drive = function(drive)
      drive.profileJob = {plan = {{op = "read", kind = "pid", index = 1}, {op = "read", kind = "pid", index = 2}}, at = 1}
    end},
  -- A two-part verdict, the bounds warning, a refused save and announcements off on a populated board.
  {name = "ground, crowded", inflight = {phase = "ground", setupVerdict = {"same_gvar", "mix_missing"}, setSource = "board",
    cellCount = 36, prime = {phase = "done", skipped = 2}, boundsCount = 3},
    drive = function(drive) drive.saveResult = "unavailable" end},
  {name = "ground, empty board, refused save", inflight = {phase = "ground", setupVerdict = "ok", setSource = "unavailable",
    prime = {phase = "done"}},
    drive = function(drive) drive.saveResult = "unavailable" end},
  {name = "restore results", inflight = {phase = "ground", setSource = "board", cellCount = 36},
    drive = function(drive)
      drive.restoreResultOpen = 1
      drive.transfer = {results = {pid1 = "ok", rate1 = "ram_ok", global = "verify_failed"}, reason = "verify_failed"}
    end},
  {name = "FC setup choices", inflight = {phase = "ground", setSource = "board", cellCount = 36},
    drive = function(drive)
      drive.fcSetupOpen, drive.fcSurface = true, rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
      drive.fcSetup = {phase = "choices", step = 5, step_headspeed = 50}
    end},
  {name = "FC setup writing", inflight = {phase = "ground", setSource = "board", cellCount = 36},
    drive = function(drive)
      drive.fcSetupOpen, drive.fcSurface = true, rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
      drive.fcSetup = {phase = "writing", run = {done = 3, total = 73, phase = "writing"}}
    end},
}
local SIZES = {{800, 480}, {480, 320}, {480, 272}}

for _, scheme in ipairs({false, "light", "dark", "unknown"}) do
  local name = Schemes.name(scheme or nil)
  local c = Schemes.colors(name)
  local allowed = schemeValues(name)
  for _, size in ipairs(SIZES) do
    for _, surface in ipairs(SURFACES) do
      local label = (scheme or "unset") .. " " .. size[1] .. "x" .. size[2] .. " " .. surface.name
      local widget, drive = view(scheme or nil, size, surface.inflight, surface.armed)
      if surface.drive then surface.drive(drive) end
      local nodes = {}
      local ok, err = pcall(Screen.buildFullscreen, nodes, widget)
      check(ok, label .. ": builds (" .. tostring(err) .. ")")
      if ok then
        for _, found in ipairs(colours(nodes, {}, "")) do
          check(allowed[found.colour], label .. ": colour " .. string.format("%06X", tonumber(found.colour) or 0)
            .. " at " .. found.where .. " is not a " .. name .. " scheme value")
        end
        local page = nodes[1]
        check(page and page.type == "rectangle" and page.w == size[1] and page.h == size[2] and page.color == c.page,
          label .. ": the page is behind everything")
        local strip, rule
        for _, node in ipairs(nodes) do
          if node.type == "rectangle" and node.x == 0 and node.y == 0 and node.w == size[1] and node.h < size[2] then strip = node end
          if node.type == "rectangle" and node.x == 0 and node.h == 1 and strip and node.y == strip.h - 1 then rule = node end
        end
        check(strip and strip.color == c.header, label .. ": the header strip is the scheme's header")
        if name == "light" then
          check(rule and rule.color == c.rule, label .. ": a rule parts the light header from the page")
        else
          check(rule == nil, label .. ": the dark header needs no rule")
        end
        local close, glyph = labelled(nodes, "X")
        if surface.armed then
          check(close == nil, label .. ": no close box while armed")
        elseif surface.name ~= "restore question" and surface.name ~= "after-landing actions"
          and surface.name ~= "parameter choice" and surface.name ~= "restore results"
          and string.sub(surface.name, 1, 8) ~= "FC setup" then
          check(close and close.color == c.error and glyph.color == c.onError, label .. ": the close box is red, its X on it")
        end
        if surface.name == "ground" or surface.name == "ground, empty board" then
          local primaryText = surface.name == "ground" and "Choose parameters" or "Set up suggested functions"
          local primary, caption = labelled(nodes, primaryText)
          check(primary and primary.color == c.accent and caption.color == c.onAccent,
            label .. ": one accented primary with its caption on the accent")
          local restore, restoreCaption = labelled(nodes, "Restore all")
          local read = labelled(nodes, "Read again")
          check(restore and read and restore.color == c.raised and read.color == c.raised and restoreCaption.color == c.error,
            label .. ": Restore all is a cell like Read again, named in the error colour")
          check(restore and read and restore.h == read.h and primary and restore.y > primary.y,
            label .. ": the secondary cells share one height under the primary")
          if surface.name == "ground" then
            local functions = labelled(nodes, "Functions")
            check(functions and functions.color == c.raised, label .. ": suggested functions are a secondary cell, short")
          end
          for _, node in ipairs(nodes) do
            if node.type == "rectangle" and node.filled and node.y > 0 and node.h > 12 and node.w < size[1] then
              check(false, label .. ": no box on the ground surface (" .. node.y .. ")")
            end
          end
        end
        -- The accent where it is text is accentInk, wherever it stands.
        local function textColour(text)
          for _, node in ipairs(nodes) do
            if node.type == "label" and value(node.text) == text then return value(node.color) end
          end
        end
        local function buttonText(text)
          for _, node in ipairs(nodes) do
            if node.type == "button" and value(node.text) == text then return node end
          end
        end
        if surface.name == "after landing" then
          check(textColour("1 parameter changed") == c.accentInk and textColour("70 -> 72  +2") == c.accentInk,
            label .. ": the count and the change are accent text, accentInk")
          local restore, caption = labelled(nodes, "Restore...")
          local continue = labelled(nodes, "Continue tuning")
          check(restore and restore.color == c.raised and caption.color == c.error and continue and continue.color == c.accent,
            label .. ": Restore... is a raised cell named in red, Continue tuning the primary")
          local back, forward = buttonText("<"), buttonText(">")
          check(back and forward and back.color == c.raised and forward.color == c.raised, label .. ": the page arrows are raised cells")
        end
        if surface.name == "restore results" then
          check(textColour("Restore results 1/1") == c.accentInk, label .. ": the title is accent text, accentInk")
          local back, forward = labelled(nodes, "<"), labelled(nodes, ">")
          check(back and forward and back.color == c.raised and forward.color == c.raised, label .. ": the page buttons are raised cells")
        end
        if surface.name == "FC setup choices" then
          check(textColour("Set up suggested functions") == c.accentInk, label .. ": the heading is accent text, accentInk")
          local chosen, other = labelled(nodes, "5"), labelled(nodes, "2")
          local nextButton, nextCaption = labelled(nodes, "Next")
          local cancel = labelled(nodes, "Cancel")
          check(chosen and other and chosen.color == c.accent and other.color == c.raised and nextButton
            and nextButton.color == c.accent and nextCaption.color == c.onAccent and cancel and cancel.color == c.raised,
            label .. ": the chosen step and Next on the accent, the others and Cancel raised")
        end
        if surface.name == "FC setup writing" then
          local track, fill
          for index, node in ipairs(nodes) do
            if node.type == "rectangle" and type(node.size) == "function" then fill, track = node, nodes[index - 1] end
          end
          check(track and fill and track.color == c.rule and fill.color == c.accent,
            label .. ": the progress track is the rule, its fill the accent")
        end
        if string.sub(surface.name, 1, 6) == "ground" and surface.name ~= "ground, reading" then
          for _, node in ipairs(nodes) do
            if node.type == "button" and node.y > 0 then
              check(node.h >= 20, label .. ": every action is at least a line of text tall (" .. node.h .. ")")
            end
          end
        end
        if surface.name == "live list" then
          local back, forward, title = buttonText("<"), buttonText(">"), buttonText("Roll")
          check(back and forward and title and back.color == c.raised and forward.color == c.raised and title.color == c.raised
            and back.textColor == c.text and forward.textColor == c.text,
            label .. ": the function arrows and the group title are raised cells")
        end
        if surface.name == "live value" then
          local resting, guards = 0, 0
          for _, node in ipairs(nodes) do
            if node.type == "box" and type(node.children) == "table" then
              for _, child in ipairs(node.children) do
                if child.type == "button" then
                  if value(child.text) == "Encoder" then
                    guards = guards + 1
                    check(child.color == c.bg or child.color == c.page, label .. ": a guard row stands on the page")
                  elseif child.text ~= nil then
                    resting = resting + 1
                    check(child.color == c.page, label .. ": a resting name row stands on the page")
                  end
                end
              end
            end
          end
          check(resting > 0 and guards > 0, label .. ": the resting rows and the guards were found (" .. resting .. ", " .. guards .. ")")
        end
        if surface.name == "group picker" then
          local chosen, other = buttonText("Roll"), buttonText("Pitch")
          check(chosen and other and chosen.color == c.accent and chosen.textColor == c.onAccent and other.color == c.raised,
            label .. ": the current group is on the accent, the others raised")
        end
        if surface.name == "parameter choice" then
          local back, forward = buttonText("<"), buttonText(">")
          local apply, applyCaption = labelled(nodes, "Apply")
          check(back and forward and back.color == c.raised and forward.color == c.raised and back.textColor == c.text
            and forward.textColor == c.text and apply and apply.color == c.accent and applyCaption.color == c.onAccent,
            label .. ": both page arrows raised, Apply the primary")
          local chosen, unchosen = buttonText("[x] P-gain"), buttonText("[  ] I-gain")
          check(chosen and unchosen and chosen.color == c.accent and chosen.textColor == c.onAccent
            and unchosen.color == c.raised and unchosen.textColor == c.text,
            label .. ": a chosen parameter on the accent, one not chosen on a raised cell")
        end
        if surface.name == "ground, reading" then
          local track, fill
          for _, node in ipairs(nodes) do
            if node.type == "rectangle" and type(node.size) == "function" then fill = node end
          end
          for index, node in ipairs(nodes) do
            if node == fill then track = nodes[index - 1] end
          end
          check(track and fill and track.color == c.rule and fill.color == c.accent,
            label .. ": the progress track is the rule, its fill the accent")
          check(textColour("Reading - Step 1 of 2") == c.accentInk, label .. ": the step text is accent text, accentInk")
        end
        if surface.name == "ground" and size[2] > 350 then
          local functions, read, restore = labelled(nodes, "Functions"), labelled(nodes, "Read again"), labelled(nodes, "Restore all")
          check(functions and read and restore and functions.y == read.y and read.y == restore.y,
            label .. ": with room, the secondary actions share one row")
        end
        if (surface.name == "ground" or surface.name == "ground, crowded") and size[2] >= 300 then
          local primary = labelled(nodes, "Choose parameters")
          local read = labelled(nodes, "Read again")
          check(primary and read and primary.h > read.h, label .. ": the primary is taller than the cells ("
            .. tostring(primary and primary.h) .. " / " .. tostring(read and read.h) .. ")")
        end
        if surface.name == "live value" then
          local plus, minus
          for _, node in ipairs(nodes) do
            if type(node.children) == "table" and node.children[1] and node.children[1].text == "+" then plus = node end
            if type(node.children) == "table" and node.children[1] and node.children[1].text == "-" then minus = node end
          end
          check(plus and plus.color == c.accent and minus and minus.color == c.warning
            and plus.children[1].color == c.onAccent and minus.children[1].color == c.onAccent,
            label .. ": plus on the accent, minus on the warning colour, both glyphs readable on their fill")
        end
      end
    end
  end
end

-- Positive controls: a colour outside the scheme is seen, nested in a child too.
check(not schemeValues("dark")[Schemes.colors("light").page], "positive control: the two schemes differ")
-- A wrong ROLE is a scheme value too: the role checks above must tell raised from accent. Proven on a node.
check(Schemes.colors("light").raised ~= Schemes.colors("light").accent, "positive control: raised and accent differ")
local injected = colours({{type = "button", color = 0x123456, children = {{type = "label", color = 0x654321}}}}, {}, "")
local lightSet = schemeValues("light")
check(#injected == 2 and not lightSet[injected[1].colour] and not lightSet[injected[2].colour],
  "positive control: an injected node and its child carry colours no scheme has, and both are found")

if #failures > 0 then
  for _, message in ipairs(failures) do print("FAIL " .. message) end
  print(#failures .. " of " .. checked .. " scheme checks failed")
  os.exit(1)
end
print("verify_inflight_scheme: " .. checked .. " checks, 0 failures")
