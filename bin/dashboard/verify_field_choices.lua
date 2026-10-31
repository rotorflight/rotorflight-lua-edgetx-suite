-- Checks what a box theme's tiles show when the pilot chooses it: the catalogue against every
-- shipped box theme, the override the runtime applies, the key bindings, and the shared settings
-- pages through the Default theme's real configure module and the real dashboard library.
-- Desktop Lua 5.3, from the repository root:
--   lua5.3 bin/dashboard/verify_field_choices.lua
-- UI controls and the model store are stubbed; the catalogue, the override, the bindings, the
-- theme's configure module and the library's load and save are real.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local SRC = ROOT .. "/src/rfsuite/"
local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local THEMES = SRC .. "widgets/dashboard/themes/"

local assertions, failures = 0, 0
local function check(condition, name)
  assertions = assertions + 1
  if not condition then
    failures = failures + 1
    print("FAIL " .. name)
  end
end

-- Theme modules read a few radio globals at load time.
for _, name in ipairs({ "WHITE", "BLACK", "RED", "GREEN", "YELLOW", "ORANGE", "GREY", "DARKGREY",
  "LIGHTGREY", "BLUE", "DARKGREEN", "COLOR_THEME_DISABLED", "COLOR_THEME_SECONDARY1",
  "COLOR_THEME_SECONDARY2", "COLOR_THEME_SECONDARY3", "COLOR_THEME_PRIMARY1", "COLOR_THEME_PRIMARY2",
  "COLOR_THEME_FOCUS", "SMLSIZE", "MIDSIZE", "DBLSIZE", "XXLSIZE", "BOLD", "FONT_STD", "FONT_L",
  "FONT_XL", "FONT_XS", "FONT_S" }) do
  _G[name] = _G[name] or 0
end
_G.lcd = _G.lcd or { RGB = function() return 0 end }
_G.rfsuite = _G.rfsuite or { session = {} }

local Controls
local DashboardLib
local loaded = {}
_G.loadScript = function(path)
  if string.sub(path, 1, #CORE) ~= CORE then return loadfile(path) end
  local rel = string.sub(path, #CORE + 1)
  if rel == "ui/controls.lua" then return function() return Controls end end
  if rel == "app/pages/settings/dashboard/lib.lua" then return function() return DashboardLib end end
  if rel == "lib/log.lua" or rel == "lib/require.lua" then return nil end
  if rel == "lib/model_preferences.lua" then
    return function() return { saveByMcuId = function() return true end } end
  end
  if loaded[rel] == nil then loaded[rel] = assert(loadfile(SRC .. rel)) end
  return loaded[rel]
end

local Fields = assert(loadfile(SRC .. "widgets/dashboard/fields.lua"))()
local Keys = assert(loadfile(SRC .. "widgets/dashboard/keys.lua"))()

local function phaseBoxes(folder, file)
  local chunk = loadfile(THEMES .. folder .. "/" .. file)
  if not chunk then return nil end
  local ok, module = pcall(chunk)
  if not ok or type(module) ~= "table" then return nil end
  local boxes = module.boxes
  if type(boxes) == "function" then
    local built
    ok, built = pcall(boxes, nil, { themeConfig = {} })
    boxes = ok and built or nil
  end
  return boxes
end

-- 1. Every shipped box theme: every reassignable box is named uniquely within its phase, and
--    the value it shows by default is in the catalogue, so its choice never starts on nothing.
local BOX_THEMES = { "default", "rfstatus", "@aerc", "@aerc-n", "@rt-rc", "@rt-rc-n", "@srb-rc" }
local PHASES = { "preflight", "inflight", "postflight" }
local reassignable = 0
for _, folder in ipairs(BOX_THEMES) do
  for _, phase in ipairs(PHASES) do
    local boxes = phaseBoxes(folder, phase .. ".lua")
    check(type(boxes) == "table", folder .. "/" .. phase .. " declares boxes")
    local seen = {}
    for _, row in ipairs(Fields.rows(boxes, phase)) do
      reassignable = reassignable + 1
      check(not seen[row.key], folder .. "/" .. phase .. " names " .. row.key .. " once")
      seen[row.key] = true
      check(row.default ~= nil, folder .. "/" .. phase .. " " .. row.key .. " shows a catalogue value")
    end
  end
end
check(reassignable > 40, "the shipped box themes have reassignable tiles (" .. reassignable .. ")")

-- 2. The override: a copy of the chosen box, the theme's tables untouched, geometry kept.
local pre = phaseBoxes("default", "preflight.lua")
local rows = Fields.rows(pre, "preflight")
local first = rows[1]
local target
for i, box in ipairs(pre) do
  if Fields.settingKey("preflight", Fields.boxId(box)) == first.key then target = i end
end
check(target ~= nil, "the first row names a box of the phase")
local original = pre[target]
local before = {}
for k, v in pairs(original) do before[k] = v end
local chosen = (first.default == "altitude") and "current" or "altitude"
local out = Fields.apply(pre, "preflight", { [first.key] = chosen })
local entry = Fields.entry(chosen)
check(out ~= pre, "a choice yields a new list")
check(out[target] ~= original, "the chosen box is a copy")
check(out[target].source == entry.source, "the copy reads the chosen source")
check(out[target].unit == entry.unit, "the copy carries the chosen unit")
check(out[target].col == original.col and out[target].row == original.row
  and out[target].colspan == original.colspan and out[target].rowspan == original.rowspan,
  "the copy keeps the box's place")
check((original.title ~= nil) == (out[target].title ~= nil), "a caption stays where there was one, and only there")
for k, v in pairs(before) do check(original[k] == v, "the theme's box keeps " .. tostring(k)) end
for i, box in ipairs(pre) do
  if i ~= target then check(out[i] == box, "an unchosen box is the theme's own (" .. i .. ")") end
end
check(Fields.apply(pre, "preflight", { [first.key] = first.default }) == pre, "a choice of the theme's own value changes nothing")
check(Fields.apply(pre, "preflight", { [first.key] = "no_such_value" }) == pre, "an unknown choice changes nothing")
check(Fields.apply(pre, "inflight", { [first.key] = chosen }) == pre, "a choice of another phase changes nothing")
check(Fields.apply(pre, "preflight", { [first.key] = "max_current" }) == pre, "a statistic is not offered to a live tile")
local computed = { { col = 1, row = 1, type = "text", subtype = "telemetry", source = "a_theme_value" } }
check(#Fields.rows(computed, "preflight") == 0, "a box showing a value the catalogue lacks is not listed")

-- A box that sizes its font to a width is sized for the value it now shows; its room is kept.
local sized
for _, box in ipairs(pre) do
  if Fields.catalogue(box) and type(box.autosize_chars) == "number" then sized = box end
end
check(sized ~= nil, "Default has a reassignable box that sizes its font")
if sized then
  local key = Fields.settingKey("preflight", Fields.boxId(sized))
  local wide = (sized.source == "voltage") and "current" or "voltage"
  local resized
  for _, box in ipairs(Fields.apply(pre, "preflight", { [key] = wide })) do
    if Fields.settingKey("preflight", Fields.boxId(box)) == key then resized = box end
  end
  check(resized and resized.autosize_chars == Fields.entry(wide).chars and resized.autosize_chars > sized.autosize_chars,
    "a resized box takes the width of its new value")
  check(resized and resized.max_chars_lowres == sized.max_chars_lowres, "a resized box keeps its room")
end

local post = phaseBoxes("default", "postflight.lua")
local statRow = Fields.rows(post, "postflight")[1]
check(statRow ~= nil and statRow.list == Fields.STATS, "a statistics tile chooses from the statistics")
local statChoice = (statRow.default == "max_altitude") and "min_voltage" or "max_altitude"
local statOut = Fields.apply(post, "postflight", { [statRow.key] = statChoice })
local statBox
for _, box in ipairs(statOut) do
  if Fields.settingKey("postflight", Fields.boxId(box)) == statRow.key then statBox = box end
end
check(statBox and statBox.stattype == Fields.entry(statChoice).stattype, "a statistic carries its stattype")
check(statBox and statBox.thresholds == nil, "a chosen value drops the theme's thresholds")

-- 3. The keys a box theme's page binds, laid over its manifest's.
local declared = { exit = "exitFullscreen" }
local bound = Keys.themeBindings({ theme_key_mdl = "suite_tool", theme_key_sys = "none" }, declared)
check(bound ~= declared and bound.mdl == "openTool", "a chosen key binds the host's action")
check(bound.sys == "none", "Nothing is a binding of its own")
check(Keys.themeBindings({ theme_key_mdl = "none" }, { mdl = "openTool" }).mdl == "none",
  "Nothing silences a key the manifest binds")
check(bound.exit == "exitFullscreen", "the manifest's bindings remain")
check(declared.mdl == nil, "the manifest's table is not written to")
check(Keys.themeBindings({}, declared) == declared, "no choice leaves the manifest's table")
local action = Keys.resolve({ key_mdl = "theme" }, "mdl", nil, bound)
check(action == "openTool", "a key on Theme resolves to the theme page's binding")

-- 4. The shared pages, through the Default theme's own configure module.
local combos
Controls = {
  SECTION_H = 30,
  appendSectionHeader = function() end,
  appendNumberField = function() return 40 end,
  appendRadioSwitch = function() return 40 end,
  appendComboSelect = function(children, x, y, w, label, options, selected, onSelect, opts)
    combos[#combos + 1] = { label = label, options = options, selected = selected, onSelect = onSelect, opts = opts }
    return 40
  end,
}
DashboardLib = assert(loadfile(SRC .. "app/pages/settings/dashboard/lib.lua"))()
local PREFIX = "cfg_system_default_"

local function openPage(pageId, prefs)
  local factory = assert(loadfile(THEMES .. "default/configure.lua"))()
  local theme = { path = "system/default", configurePath = CORE .. "widgets/dashboard/themes/default/configure.lua" }
  local module = factory({ theme = theme, page = { id = pageId } })
  combos = {}
  module.build({ children = {}, x = 0, y = 0, w = 800, preferences = prefs, page = { id = pageId } })
  return module
end

local function save(module, prefs)
  module.onSave({ preferences = prefs, savePreferences = function() return true end, reportSave = function() end })
end

DashboardLib.setEditScope(nil)
local prefs = { dashboard = {} }
local page = openPage("postflight", prefs)
local postRows = Fields.rows(post, "postflight")
check(#combos == #postRows, "the Statistics page lists every statistics tile (" .. #combos .. ")")
for i, combo in ipairs(combos) do
  check(combo.selected == postRows[i].default, "a choice starts on the theme's own value (" .. i .. ")")
  check(type(combo.opts) == "table" and type(combo.opts.helpText) == "string", "a row carries its help (" .. i .. ")")
end
combos[1].onSelect(statChoice)
save(page, prefs)
check(prefs.dashboard[PREFIX .. postRows[1].key] == statChoice, "the radio's standard stores the choice")
check(prefs.dashboard[PREFIX .. "v_min"] == nil, "a phase page saves nothing of Look")

local look = openPage("look", prefs)
check(#combos == 0, "Look shows no tile")
save(look, prefs)
check(prefs.dashboard[PREFIX .. postRows[1].key] == statChoice, "saving Look keeps the tile choices")

-- The choice reaches the runtime's configuration, as reloadActiveTheme reads it.
local cfg = DashboardLib.getThemeConfig(prefs, "system/default", {}, nil)
check(cfg[postRows[1].key] == statChoice, "the theme configuration carries the choice")

-- A model's own choice: one equal to the standard is not stored, one that deviates is.
local modelPrefs = { dashboard = {} }
_G.rfsuite.session = { mcu_id = "0123456789ABCDEF01234567", modelPreferences = modelPrefs }
DashboardLib.setEditScope("model")
local modelPage = openPage("postflight", prefs)
check(combos[1].selected == statChoice, "the model page starts on the radio's standard")
save(modelPage, prefs)
check(modelPrefs.dashboard[PREFIX .. postRows[1].key] == nil, "a model choice equal to the standard is not stored")
check(modelPrefs.dashboard[PREFIX .. postRows[2].key] == nil, "an untouched tile is not stored for the model")
modelPage = openPage("postflight", prefs)
combos[2].onSelect("max_watts")
save(modelPage, prefs)
check(modelPrefs.dashboard[PREFIX .. postRows[2].key] == "max_watts", "a model choice that deviates is stored")
DashboardLib.setEditScope(nil)
_G.rfsuite.session = {}

local keysPage = openPage("keys", prefs)
check(#combos == #Keys.THEME_KEYS, "the Keys page lists every key")
local mdlRow
for i, entry in ipairs(Keys.THEME_KEYS) do
  if entry.id == "mdl" then mdlRow = combos[i] end
  if entry.id == "sys" then
    check(combos[i].opts.active == false, "a key the radio-wide page holds is greyed")
  end
end
check(mdlRow and mdlRow.opts.active ~= false, "a key on Theme can be chosen")
mdlRow.onSelect("flight_log")
save(keysPage, prefs)
check(prefs.dashboard[PREFIX .. "theme_key_mdl"] == "flight_log", "the Keys page stores the binding")
cfg = DashboardLib.getThemeConfig(prefs, "system/default", {}, nil)
check(Keys.themeBindings(cfg, nil).mdl == "openTool:tools_flight_log_page", "the stored binding binds its action")

-- The Info bar page: the buttons' end, then six positions, each starting on the bar's own default
-- (widgets/dashboard/fullscreen_controls.lua `M.layout`, which states the same defaults).
local BarControls = assert(loadfile(SRC .. "widgets/dashboard/fullscreen_controls.lua"))()
local barPage = openPage("bar", prefs)
check(#combos == 7, "the Info bar page lists the buttons' end and six positions (" .. #combos .. ")")
local defaultSide, defaultItems = BarControls.layout({})
check(combos[1].selected == defaultSide, "Buttons starts on the bar's default end")
local shown = {}
for i = 2, 7 do
  check(type(combos[i].opts) == "table" and type(combos[i].opts.helpText) == "string", "a position carries its help (" .. (i - 1) .. ")")
  if combos[i].selected ~= "none" then shown[#shown + 1] = combos[i].selected end
end
check(table.concat(shown, ",") == table.concat(defaultItems, ","), "the positions start on the bar's defaults")
combos[1].onSelect("right")
combos[2].onSelect("link_value")
combos[3].onSelect("none")
save(barPage, prefs)
check(prefs.dashboard[PREFIX .. "bar_buttons"] == "right", "the Info bar page stores the buttons' end")
check(prefs.dashboard[PREFIX .. "bar_slot1"] == "link_value", "the Info bar page stores a position")
cfg = DashboardLib.getThemeConfig(prefs, "system/default", {}, nil)
local side, items = BarControls.layout(cfg)
check(side == "right" and items[1] == "link_value" and items[2] == "link_bars",
  "the bar draws what the page stored, an emptied position left out")

-- 4b. Every other box theme that declares the shared pages: each phase page lists exactly its
--     phase's reassignable tiles, and its Keys page every key, through the theme's own configure
--     module. A theme declaring the pages has to take the full screen as well.
local MIGRATED = {}
for _, folder in ipairs(BOX_THEMES) do
  local init = assert(loadfile(THEMES .. folder .. "/init.lua"))()
  if folder ~= "default" and type(init.pages) == "table" then MIGRATED[#MIGRATED + 1] = folder end
end
-- Every shipped box theme is on the shared pages now; one left behind would be listed here.
check(#MIGRATED == #BOX_THEMES - 1, "every shipped box theme declares the shared pages (" .. #MIGRATED .. ")")
for _, folder in ipairs(MIGRATED) do
  for _, phase in ipairs(PHASES) do
    local factory = assert(loadfile(THEMES .. folder .. "/configure.lua"))()
    local module = factory({ theme = { path = "system/" .. folder,
      configurePath = CORE .. "widgets/dashboard/themes/" .. folder .. "/configure.lua" }, page = { id = phase } })
    combos = {}
    module.build({ children = {}, x = 0, y = 0, w = 800, preferences = { dashboard = {} }, page = { id = phase } })
    local expected = Fields.rows(phaseBoxes(folder, phase .. ".lua"), phase)
    check(#combos == #expected, folder .. " " .. phase .. " page lists its " .. #expected .. " tiles (" .. #combos .. ")")
    for i, combo in ipairs(combos) do
      check(expected[i] and combo.selected == expected[i].default, folder .. " " .. phase .. " row " .. i .. " starts on the theme's value")
    end
  end
  local factory = assert(loadfile(THEMES .. folder .. "/configure.lua"))()
  local module = factory({ theme = { path = "system/" .. folder,
    configurePath = CORE .. "widgets/dashboard/themes/" .. folder .. "/configure.lua" }, page = { id = "keys" } })
  combos = {}
  module.build({ children = {}, x = 0, y = 0, w = 800, preferences = { dashboard = {} }, page = { id = "keys" } })
  check(#combos == #Keys.THEME_KEYS, folder .. " Keys page lists every key")
  -- Look is the theme's own form, as before: it builds, and lists none of the shared rows.
  factory = assert(loadfile(THEMES .. folder .. "/configure.lua"))()
  module = factory({ theme = { path = "system/" .. folder,
    configurePath = CORE .. "widgets/dashboard/themes/" .. folder .. "/configure.lua" }, page = { id = "look" } })
  combos = {}
  local built = pcall(module.build, { children = {}, x = 0, y = 0, w = 800, preferences = { dashboard = {} }, page = { id = "look" } })
  check(built, folder .. " Look builds")
  local init = assert(loadfile(THEMES .. folder .. "/init.lua"))()
  check(init.fullscreen == "theme", folder .. " takes the full screen")
  check(type(init.pages) == "table" and #init.pages == 6, folder .. " declares its six pages")
end

-- 5. Per-Model Settings describes such a setting as the pages show it, not by its stored name.
local Common = {
  pageT = function() return function(_, _, fallback) return fallback end end,
  saveFailureReason = function(_, reason) return reason end,
  resetPageState = function() end,
  createFormRuntime = function()
    return { setRequestRebuild = function() end, markDirty = function() end }
  end,
}
local commonChunk = function() return Common end
local pageLoad = _G.loadScript
_G.loadScript = function(path, mode)
  if path == CORE .. "app/pages/settings/common.lua" then return commonChunk end
  return pageLoad(path, mode)
end
_G.rfsuite.palette = { text = 1, border = 2 }
_G.SMLSIZE = 0
_G.lvgl = { UI_ELEMENT_HEIGHT = 32 }
Controls.labelY = function(y) return y end
Controls.appendSectionHeader = function() end
local defaultTheme = { path = "system/default", name = "Default",
  configurePath = CORE .. "widgets/dashboard/themes/default/configure.lua" }
DashboardLib.listThemes = function() return { defaultTheme } end
DashboardLib.getConfigurableThemes = function(themes) return themes end
local postKey = postRows[1].key
local modelDashboard = { overrides = true,
  [PREFIX .. postKey] = "max_altitude", [PREFIX .. "theme_key_mdl"] = "flight_log" }
local radio = { dashboard = { model_overrides = true, [PREFIX .. postKey] = postRows[1].default } }
_G.rfsuite.preferences = radio
_G.rfsuite.session = { mcu_id = "0123456789ABCDEF01234567", modelPreferences = { dashboard = modelDashboard } }
local overrides = assert(loadfile(SRC .. "app/pages/settings/dashboard/overrides/page.lua"))()
local children = {}
overrides.build({ children = children, preferences = radio, x = 0, y = 0, w = 800 })
local text = {}
for _, child in ipairs(children) do
  if type(child.text) == "string" then text[#text + 1] = child.text end
end
text = table.concat(text, "\n")
local caption = postRows[1].title or postRows[1].defaultLabel
check(string.find(text, "page_postflight)@: " .. caption, 1, true) ~= nil, "a tile setting names its page and caption")
check(string.find(text, Fields.entry("max_altitude").label, 1, true) ~= nil, "a tile setting names the chosen value")
check(string.find(text, Fields.entry(postRows[1].default).label, 1, true) ~= nil, "the standard is named by its value")
check(string.find(text, "theme_key)@ MDL", 1, true) ~= nil, "a key setting names the key")
check(string.find(text, "field_postflight_", 1, true) == nil and string.find(text, "theme_key_mdl", 1, true) == nil,
  "no stored name is shown")
overrides.onClose()

-- 6. The theme index a shipped theme is listed from says its icons were checked, so the theme
--    scan takes them as named; the checked-in fallback has to hold to that, icon for icon.
local index = assert(loadfile(SRC .. "app/pages/settings/dashboard/theme_index.lua"))()
for _, row in ipairs(index) do
  check(row.checked == true, row.folder .. " index row is marked checked")
  local function exists(name)
    local f = io.open(THEMES .. row.folder .. "/" .. name, "rb")
    if f then f:close() end
    return f ~= nil
  end
  if row.icon then check(exists(row.icon), row.folder .. " index icon exists") end
  for _, page in ipairs(row.pages or {}) do
    if page.icon then check(exists(page.icon), row.folder .. " page " .. page.id .. " icon exists") end
  end
end
-- A checked row's icons are not opened on the radio; an unchecked one's are, as before.
local opened = 0
local realOpen = io.open
io.open = function(path, ...)
  if type(path) == "string" and string.find(path, "/icons/", 1, true) then opened = opened + 1 end
  return realOpen(path, ...)
end
local Lib = assert(loadfile(SRC .. "app/pages/settings/dashboard/lib.lua"))()
local listed = Lib.listThemes(true)
io.open = realOpen
check(type(listed) == "table" and #listed >= #index, "the theme list is built from the index")
check(opened == 0, "no page icon of a checked row is opened (" .. opened .. ")")

print(string.format("%d assertions, %d failures", assertions, failures))
os.exit(failures == 0 and 0 or 1)
