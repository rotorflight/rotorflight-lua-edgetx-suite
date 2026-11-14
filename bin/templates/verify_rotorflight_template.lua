-- Drive the Rotorflight model template's wizard script through its two screens and check what
-- it refuses and what it writes into the model. The radio, lvgl and lib/model_radio.lua are
-- stubs; the template script itself is the real file.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- Seven physical switches: SA..SF with three positions, SW1 with two. A switch's first position
-- is the answer a whole-switch picker stores; its mix source is a separate id.
local NAMES = { "SA", "SB", "SC", "SD", "SE", "SF", "SW1" }
local POSITIONS = { 3, 3, 3, 3, 3, 3, 2 }
local FIRST, PER = 1, 3
local function first(n) return FIRST + (n - 1) * PER end
local function source(n) return 100 + n end
local SW = {}
for n, name in ipairs(NAMES) do SW[name] = n end

local function numberOf(swsrc)
  if swsrc == nil or swsrc < FIRST then return nil end
  return math.floor((swsrc - FIRST) / PER) + 1
end

local R = {
  TRIM_OFF = -1,
  CHANNELS = { { key = "throttle", channel = 6 } },
  firstPositionOf = function(swsrc)
    local n = numberOf(swsrc)
    return n and first(n) or nil
  end,
  switchPositionCount = function(swsrc)
    local n = numberOf(swsrc)
    return n and POSITIONS[n] or nil
  end,
  switchSource = function(swsrc)
    local n = numberOf(swsrc)
    return n and source(n) or nil
  end,
  switchFromSource = function(id)
    for n = 1, #NAMES do
      if source(n) == id then return first(n) end
    end
    return nil
  end,
  switches = function(minPositions)
    local list = {}
    for n, name in ipairs(NAMES) do
      if POSITIONS[n] >= minPositions then list[#list + 1] = { swsrc = first(n), name = name } end
    end
    return list
  end,
  clearChannel = function() return true end,
  setChannelName = function() end,
  inputSource = function(index) return 1 + index end,
  writeThrottleChannel = function() return true end
}

-- `opts.noSuite`: the card carries no lib/model_radio.lua. `opts.noLvgl`: a radio without the
-- lvgl module (EdgeTX before 2.11), where only lcd drawing exists.
local function newRadio(opts)
  opts = opts or {}
  local radio = { inputs = {}, mixes = {}, modules = { [0] = { Type = 5 }, [1] = { Type = 0 } },
    builds = 0, drawn = {} }
  if opts.noLvgl then
    _G.lvgl = nil
  else
    _G.lvgl = {
      SRC_SWITCH = 0x10, SRC_CLEAR = 0x01,
      clear = function() radio.children = nil end,
      -- Every screen is one page; its body is what the checks read.
      build = function(children)
        local page = children[1]
        radio.builds = radio.builds + 1
        radio.page = page
        radio.children = (page and page.type == "page") and page.children or children
      end
    }
  end
  _G.lcd = {
    clear = function() end,
    drawText = function(_, _, text) radio.drawn[#radio.drawn + 1] = text end
  }
  _G.model = {
    getInputsCount = function(index) return #(radio.inputs[index] or {}) end,
    deleteInput = function(index, line) table.remove(radio.inputs[index], line + 1) end,
    insertInput = function(index, line, value)
      radio.inputs[index] = radio.inputs[index] or {}
      table.insert(radio.inputs[index], line + 1, value)
    end,
    insertMix = function(channel, line, value) radio.mixes[channel] = value end,
    setModule = function(index, value)
      radio.modules[index] = radio.modules[index] or {}
      for k, v in pairs(value) do radio.modules[index][k] = v end
    end,
    getModule = function(index) return radio.modules[index] end
  }
  -- The stub above stands for lib/model_radio.lua, so what the template reads from it is checked
  -- against the real module once.
  do
    local template = assert(io.open("src/templates/5.Rotorflight/Rotorflight.lua", "rb")):read("a")
    local real = assert(loadfile("src/rfsuite/lib/model_radio.lua"))()
    local seen = 0
    for field in string.gmatch(template, "%f[%w_]R%.([%a_][%w_]*)") do
      seen = seen + 1
      assert(real[field] ~= nil, "lib/model_radio.lua has no " .. field)
    end
    assert(seen > 0, "the template reads nothing from its radio module")
  end
  _G.loadScript = function(path)
    if string.find(path, "ui/palette.lua", 1, true) then
      return function() return { text = 1, muted = 2, border = 3, warning = 4, error = 5, ok = 6 } end
    end
    assert(string.find(path, "lib/model_radio.lua", 1, true), "unexpected module: " .. path)
    if opts.noSuite then return nil end
    return function() return R end
  end
  _G.LCD_W, _G.LCD_H = 480, 272
  _G.EVT_VIRTUAL_EXIT, _G.EVT_VIRTUAL_ENTER = 1001, 1002
  radio.script = assert(loadfile("src/templates/5.Rotorflight/Rotorflight.lua"))()
  radio.script.init()
  radio.result = radio.script.run(0)
  return radio
end

-- The controls of the screen on display, by the row label they sit beside.
local function control(radio, labelKey)
  local children = assert(radio.children, "nothing built")
  for i, child in ipairs(children) do
    if child.type == "label" and string.find(child.text or "", labelKey, 1, true) then
      return children[i + 1]
    end
  end
  return nil
end

local function button(radio, textKey)
  for _, child in ipairs(radio.children or {}) do
    if child.type == "button" and string.find(child.text or "", textKey, 1, true) then return child end
  end
  return nil
end

local function hasText(radio, key)
  for _, child in ipairs(radio.children or {}) do
    if child.type == "label" and string.find(child.text or "", key, 1, true) then return true end
  end
  return false
end

local function pick(radio, rowKey, switchName)
  local c = assert(control(radio, "row_" .. rowKey), "no row " .. rowKey)
  if c.type == "switch" then
    c.set(first(SW[switchName]) + 2)   -- the hold row takes one POSITION of the switch
  else
    c.set(switchName and source(SW[switchName]) or 0)
  end
end

local function press(radio, textKey)
  local b = assert(button(radio, textKey), "no button " .. textKey)
  b.press()
  radio.script.run(0)
end

local function firstScreen(radio, arm, hold, gov, profile, rescue)
  pick(radio, "arm", arm)
  pick(radio, "hold", hold)
  pick(radio, "gov", gov)
  pick(radio, "profile", profile)
  pick(radio, "rescue", rescue)
  press(radio, "next_button")
end

-- 1. One switch on arming and rescue is refused on the first screen.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SF", "SA", "SD", "SW1")
  check(hasText(radio, "same_switch"), "arm and rescue on one switch is refused")
  check(button(radio, "create_button") == nil, "a refused first screen does not move on")
end

-- 2. Governor and profiles may share a switch; so may the hold and the governor, which drive
-- one channel. The hold beside the profiles on one switch is two functions and is refused.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SF", "SE", "SE", "SB")
  check(not hasText(radio, "same_switch"), "governor and profile on one switch pass")
  check(button(radio, "create_button") ~= nil, "the second screen follows")

  radio = newRadio()
  firstScreen(radio, "SW1", "SA", "SA", "SD", "SB")
  check(not hasText(radio, "same_switch"), "hold on the governor's switch passes")

  radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SE", "SE", "SB")
  check(hasText(radio, "same_switch"), "hold on the profile switch is refused")
end

-- 3. The hold on the arming switch is refused.
do
  local radio = newRadio()
  firstScreen(radio, "SB", "SB", "SA", "SD", "SF")
  check(hasText(radio, "same_switch"), "hold on the arming switch is refused")
end

-- 4. An optional channel on a switch already in use is refused on the second screen.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SA", "SD", "SF")
  pick(radio, "blackbox", "SW1")
  press(radio, "create_button")
  check(hasText(radio, "same_switch"), "blackbox on the arming switch is refused")
  check(radio.inputs[4] == nil, "nothing is written while a problem stands")
end

-- 5. Blackbox skipped, backup on its own switch, module external: what lands in the model.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SA", "SD", "SF")
  pick(radio, "backup", "SC")
  local module = assert(control(radio, "row_module"), "no module row")
  check(module.get() == 1, "the module choice starts on internal")
  module.set(2)
  press(radio, "create_button")
  check(radio.inputs[8] == nil, "a skipped blackbox leaves the template's input alone")
  check(radio.inputs[9] ~= nil and radio.inputs[9][1].source == source(SW.SC),
    "the backup input carries the chosen switch")
  check(radio.mixes[9] ~= nil, "the backup channel is wired")
  check(radio.modules[1].Type == 5 and radio.modules[1].channelsCount == 16,
    "the external module is CRSF with 16 channels")
  check(radio.modules[0].Type == 0, "the internal module is switched off")
  check(hasText(radio, "row_unused"), "the closing screen says the blackbox is not used")
end

-- 6. Internal module: the template's own module setting is not touched.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SA", "SD", "SF")
  press(radio, "create_button")
  check(radio.modules[0].Type == 5 and radio.modules[1].Type == 0, "internal leaves both slots as they are")
  check(radio.inputs[4] ~= nil and radio.inputs[4][1].source == source(SW.SW1), "arming is written")
end

-- 7. The script asks for the lvgl layout, so the radio puts the form's controls in its focus
-- group: the rotary moves between them, ENTER opens a picker, RTN reaches the page's back.
do
  local radio = newRadio()
  check(radio.script.useLvgl == true, "the script asks for the lvgl layout")
end

-- 8. RTN on a page reaches the script twice: the press edge as a raw event, then the page's own
-- back. On the second screen that is one step back, not the end of the dialog; on the first
-- screen and on the closing screen it leaves.
do
  local radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SA", "SD", "SF")
  check(button(radio, "create_button") ~= nil, "the second screen is up")
  local pressEdge = 0x0600 + 7
  check(radio.script.run(pressEdge) == 0, "the press edge of RTN does not end the dialog")
  radio.page.back()
  check(radio.script.run(0) == 0, "back on the second screen does not end the dialog")
  check(button(radio, "next_button") ~= nil, "back on the second screen shows the first")
  radio.page.back()
  check(radio.script.run(0) ~= 0, "back on the first screen leaves")

  radio = newRadio()
  firstScreen(radio, "SW1", "SE", "SA", "SD", "SF")
  press(radio, "create_button")
  check(hasText(radio, "next_steps"), "the closing screen is up")
  radio.page.back()
  check(radio.script.run(0) ~= 0, "back on the closing screen leaves")
end

-- 9. No suite on the card, lvgl present: lcd drawing does nothing in the lvgl layout, so the
-- notice is a page of its own, built once, that RTN (the page's back) and a button both close.
do
  local radio = newRadio({ noSuite = true })
  for _ = 1, 3 do radio.script.run(0) end
  check(radio.builds == 1, "the notice page is built once, not on every pass")
  check(radio.page ~= nil and radio.page.type == "page", "the notice is a page")
  check(radio.page ~= nil and radio.page.icon == nil, "the notice names no suite file as its icon")
  for _, key in ipairs({ "fallback_created", "fallback_needs_1", "fallback_needs_2",
    "fallback_needs_3", "fallback_close" }) do
    check(hasText(radio, key), "the notice carries " .. key)
  end
  check(#radio.drawn == 0, "nothing is drawn with lcd in the lvgl layout")
  local back = radio.page and radio.page.back
  check(back ~= nil, "the notice page has a back")
  if back then
    back()
    check(radio.script.run(0) ~= 0, "back closes the notice")
  end

  radio = newRadio({ noSuite = true })
  local close = button(radio, "close_button")
  check(close ~= nil, "the notice has a Close button")
  if close then
    close.press()
    check(radio.script.run(0) ~= 0, "Close closes the notice")
  end
end

-- 10. No lvgl at all: the notice is drawn with lcd, and ENTER closes it.
do
  local radio = newRadio({ noLvgl = true })
  check(radio.builds == 0, "nothing is built without lvgl")
  local seen = false
  for _, text in ipairs(radio.drawn) do
    if string.find(text, "fallback_created", 1, true) then seen = true end
  end
  check(seen, "the notice is drawn with lcd without lvgl")
  check(radio.script.run(_G.EVT_VIRTUAL_ENTER) ~= 0, "ENTER closes the lcd notice")
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
