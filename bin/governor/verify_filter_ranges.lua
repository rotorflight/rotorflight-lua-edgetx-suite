-- Build Setup > Governor > Filters through the real number-field control and check that every row
-- edits the range the firmware accepts (src/main/cli/settings.c: gov_rpm_filter, gov_pwr_filter,
-- gov_tta_filter, gov_ff_filter and gov_d_filter are all VAR_UINT8 {0, 250}), that a stored value
-- above the old Precomp Bandwidth limit is shown as stored, and that a save writes the value set.
-- Run from the repository root under lua5.3.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local sourceRoot = "src/rfsuite/"
local queue = { entries = {} }
function queue:add(entry) self.entries[#self.entries + 1] = entry end
local mspState = { queue = queue }

local saved = {}
local stubs = {
  ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
  ["tasks/msp/save_pipeline.lua"] = {
    start = function(opts) saved[#saved + 1] = opts; return true end,
    takeResult = function() end,
  },
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["app/pages/settings/common.lua"] = {
    pageT = function() return function(_, _, fallback) return fallback end end,
    failPageRead = function(ui) ui.loading = false; ui.runtime.readPending = false end,
    resetPageState = function(ui) ui.loaded = false; ui.dirty = false; ui.runtime = nil end,
  },
  ["core/display_profile.lua"] = false,
}
function loadScript(path)
  local relative = assert(string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$"), path)
  local stub = stubs[relative]
  if stub == false then return nil end
  if stub then return function() return stub end end
  return loadfile(sourceRoot .. relative)
end
_G.rfsuite = { session = {}, palette = {}, paths = { core = "/SCRIPTS/RFSUITE/core" } }

local GovernorApi = assert(loadfile(sourceRoot .. "tasks/msp/api/governor_config.lua"))()
local page = assert(loadfile(sourceRoot .. "app/pages/setup/governor/filters/page.lua"))()

-- The board's record, with Precomp Bandwidth above the old 25 Hz limit.
local FF_STORED = 100
local reply = {}
for i, v in ipairs(GovernorApi.simulatorResponse) do reply[i] = v end
local FF_BYTE = 24 -- 1 mode + 9 u16 + handover, pwr, rpm, tta: the order of buildWritePayload
equal(reply[FF_BYTE], 10, "simulator record carries gov_ff_filter at byte " .. FF_BYTE)
reply[FF_BYTE] = FF_STORED

local function build()
  local children = {}
  page.build({ children = children, x = 0, y = 0, w = 480, h = 272, i18n = nil })
  return children
end

-- Open the page: the read it queues is answered with the board's record.
build()
local read = queue.entries[1]
equal(read ~= nil, true, "page queues the governor read")
read:processReply(reply)
equal(page.canSave(), true, "read completes")

-- The numberEdit after each row label.
local function editorsByLabel(children)
  local found, label = {}, nil
  for _, child in ipairs(children) do
    if child.type == "label" then label = child.text end
    if child.type == "numberEdit" and label then found[label] = child; label = nil end
  end
  return found
end

local editors = editorsByLabel(build())
local tops = {
  ["Headspeed Filter Cutoff"] = "250Hz",
  ["Voltage Filter Cutoff"] = "250Hz",
  ["TTA Bandwidth"] = "250Hz",
  ["Precomp Bandwidth"] = "250Hz",
  ["D-Term Cutoff"] = "25.0Hz",
}
for label, top in pairs(tops) do
  local edit = editors[label]
  equal(edit ~= nil, true, label .. " row drawn")
  if edit then
    equal(edit.max, 250, label .. " editor steps (0..250 raw)")
    equal(edit.display(edit.max), top, label .. " top value shown")
  end
end

local ff = editors["Precomp Bandwidth"]
if ff then
  equal(ff.display(ff.get()), FF_STORED .. "Hz", "Precomp Bandwidth shows the stored value")
  ff.set(ff.max)
end
equal(page.onSave({}), true, "save starts")
local step = saved[1] and saved[1].steps and saved[1].steps[1]
equal(step and step.payload[FF_BYTE], 250, "save writes the value set at byte " .. FF_BYTE)

print(checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
