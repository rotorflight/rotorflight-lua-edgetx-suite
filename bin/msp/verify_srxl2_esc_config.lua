-- Host regression checks for Setup > ESC & Motors > SRXL2 ESC and its MSP module
-- (MSP2_GET_SRXL2_ESC_CONFIG 0x5F16 / MSP2_SET_SRXL2_ESC_CONFIG 0x5F17).
--
--     lua5.3 bin/msp/verify_srxl2_esc_config.lua [repository root]
--
-- The wire sizes follow the firmware handler: the read answers a payload version byte (1),
-- U16 throttle_rate_hz, U8 telem_interval_frames and U8 motor2_channel; the write takes the
-- same three fields without the version byte and is refused at any other length. The page
-- writes back what it read, so a reply it cannot decode, and an error reply from a firmware
-- without the message, must leave it with nothing to save.
local root = (arg and arg[1]) or "."
local function source(path) return root .. "/" .. path end

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("  FAIL  " .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

local function readFile(path)
  local f = io.open(source(path), "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function cardPaths()
  local chunk = loadfile(source("src/rfsuite/lib/paths.lua"))
  return chunk and chunk() or nil
end

local apiChunk = loadfile(source("src/rfsuite/tasks/msp/api/srxl2_esc_config.lua"))
local pageChunk = loadfile(source("src/rfsuite/app/pages/setup/esc_motors/srxl2/page.lua"))
check("the MSP module exists", apiChunk ~= nil)
check("the page exists", pageChunk ~= nil)
if not apiChunk or not pageChunk then
  print(string.format("\n%d of %d checks FAILED", failures, checks))
  os.exit(1)
end

local Api = apiChunk()

print("api: decode and encode")
do
  -- throttle 333 Hz (0x014D), telemetry every 9 frames, motor 2 on channel 4
  local parsed = Api.parse({ 1, 0x4D, 0x01, 9, 4 })
  check("a version-1 reply decodes", parsed ~= nil)
  if parsed then
    check("throttle_rate_hz", parsed.throttle_rate_hz == 333, parsed.throttle_rate_hz)
    check("telem_interval_frames", parsed.telem_interval_frames == 9, parsed.telem_interval_frames)
    check("motor2_channel", parsed.motor2_channel == 4, parsed.motor2_channel)
    local payload = Api.buildWritePayload(parsed)
    check("the write is exactly 4 bytes", #payload == 4, #payload)
    check("the write is the reply without its version byte",
      payload[1] == 0x4D and payload[2] == 0x01 and payload[3] == 9 and payload[4] == 4,
      table.concat(payload, ","))
  end
  check("a reply of another payload version is refused", Api.parse({ 2, 0x4D, 0x01, 9, 4 }) == nil)
  check("a short reply is refused", Api.parse({ 1, 0x4D, 0x01, 9 }) == nil)
  check("bytes after the version-1 fields are ignored", Api.parse({ 1, 250, 0, 7, 0, 99 }) ~= nil)
  check("read and write commands", Api.command == 0x5F16 and Api.writeCommand == 0x5F17)
  local sim = Api.parse(Api.simulatorResponse)
  check("the simulator reply decodes to the firmware defaults",
    sim ~= nil and sim.throttle_rate_hz == 250 and sim.telem_interval_frames == 7 and sim.motor2_channel == 0)
end

-- The page, driven through its own lifecycle with the queue, controls and save pipeline stubbed.
local Palette = assert(loadfile(source("src/rfsuite/ui/palette.lua")))()
_G.rfsuite = { palette = Palette, paths = cardPaths() }
local Common = assert(loadfile(source("src/rfsuite/app/pages/settings/common.lua")))()
_G.getTime = function() return 100 end
_G.SMLSIZE = 1

local queued, fields, saveRequest = {}, {}, nil
local modules = {
  ["app/pages/settings/common.lua"] = Common,
  ["ui/palette.lua"] = Palette,
  ["ui/controls.lua"] = {
    STATIC_SECTION_H = 1,
    appendStaticSectionHeader = function() end,
    appendNumberField = function(_, _, _, _, label, opts)
      fields[#fields + 1] = { label = label, opts = opts }
      return 1
    end
  },
  ["tasks/msp/runtime.lua"] = {
    getState = function()
      return { queue = { add = function(_, message) queued[#queued + 1] = message end } }
    end
  },
  ["tasks/msp/api/srxl2_esc_config.lua"] = Api,
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["tasks/msp/save_pipeline.lua"] = {
    takeResult = function() end,
    start = function(request) saveRequest = request; return true end
  }
}
_G.loadScript = function(path)
  local relative = string.match(path, "rfsuite%-core/(.+)$")
  local value = modules[relative]
  if not value then return nil end
  return function() return value end
end

local page = pageChunk()
local rebuilds = 0
local function onRebuild() rebuilds = rebuilds + 1 end
local ctx = { requestRebuild = onRebuild, i18n = {} }

local function build()
  fields = {}
  local children = {}
  page.build({ children = children, x = 0, y = 0, w = 480, h = 320, i18n = {},
    requestRebuild = onRebuild })
  return children
end

local function hasText(children, needle)
  for i = 1, #children do
    local text = children[i].text
    if type(text) == "string" and string.find(text, needle, 1, true) then return true end
  end
  return false
end

local function open()
  queued, saveRequest = {}, nil
  page.wakeup(ctx)
  return queued[#queued]
end

local function trySave()
  local reported = nil
  local ok = page.onSave({ i18n = {}, reportSave = function(r) reported = r end })
  return ok, reported
end

print("page: a board that answers")
do
  local read = open()
  check("opening queues one read of 0x5F16", #queued == 1 and read and read.command == 0x5F16, #queued)
  check("Save waits for the read", page.canSave() == false)
  read.processReply(read, { 1, 0x4D, 0x01, 9, 0 })
  build()
  check("two rows are drawn", #fields == 2, #fields)
  local interval, motor2 = fields[1], fields[2]
  if interval and motor2 then
    check("Telemetry Interval is 0..255", interval.opts.min == 0 and interval.opts.max == 255)
    check("Motor 2 Channel is 0..31", motor2.opts.min == 0 and motor2.opts.max == 31)
    check("0 reads as Off", motor2.opts.display(0) == "Off" and interval.opts.display(0) == "Off")
    check("a channel reads as its number", motor2.opts.display(5) == "5")
    check("both rows carry an inline help text",
      type(interval.opts.helpText) == "string" and type(motor2.opts.helpText) == "string")
    check("the values shown are the board's", interval.opts.get() == 9 and motor2.opts.get() == 0)
    rebuilds = 0
    interval.opts.set(0)
    check("an edit does not rebuild while the editor is open", rebuilds == 0, rebuilds)
    check("closing the editor rebuilds so the unsaved notice shows",
      type(interval.opts.edited) == "function" and (interval.opts.edited() or true) and rebuilds == 1, rebuilds)
    local children = build()
    check("the unsaved notice is drawn", hasText(children, "Unsaved changes"))
    motor2 = fields[2]
    rebuilds = 0
    motor2.opts.set(4)
    if type(motor2.opts.edited) == "function" then motor2.opts.edited() end
    check("a second edit with the notice already shown does not rebuild again", rebuilds == 0, rebuilds)
    check("an edit marks the page unsaved", page.hasUnsavedChanges() == true)
  end
  local ok = trySave()
  local step = saveRequest and saveRequest.steps and saveRequest.steps[1]
  check("Save starts the pipeline", ok == true and step ~= nil)
  if step then
    local p = step.payload
    check("Save writes 0x5F17", step.command == 0x5F17, step.command)
    check("Save writes 4 bytes: the rate as read, then the edits",
      #p == 4 and p[1] == 0x4D and p[2] == 0x01 and p[3] == 0 and p[4] == 4, table.concat(p, ","))
    check("Save reboots the flight controller", saveRequest.reboot == true)
  end
end

print("page: a firmware without the message")
do
  page.onClose()
  local read = open()
  check("reopening after close reads again", read ~= nil and read.command == 0x5F16)
  read.errorHandler(read, "refused")
  local children = build()
  check("no rows are drawn", #fields == 0, #fields)
  check("the page says the firmware does not offer the settings",
    hasText(children, "does not offer the SRXL2 ESC settings"))
  local ok, reported = trySave()
  check("Save is refused", ok == false and saveRequest == nil)
  check("the refusal names the firmware",
    reported ~= nil and string.find(reported.message or "", "does not offer", 1, true) ~= nil)
end

print("page: a read that fails or cannot be decoded")
do
  page.onClose()
  local read = open()
  read.errorHandler(read, "max_retries")
  local children = build()
  check("a timeout shows the read-failed notice, not the firmware notice",
    #fields == 0 and hasText(children, "read_failed") and not hasText(children, "does not offer"))
  check("Save is refused after a timeout", trySave() == false and saveRequest == nil)

  page.onClose()
  read = open()
  read.processReply(read, { 2, 0x4D, 0x01, 9, 0 })
  build()
  check("a reply of another version draws no rows", #fields == 0, #fields)
  check("Save is refused after an undecodable reply", trySave() == false and saveRequest == nil)

  page.onReload()
  read = queued[#queued]
  check("Reload reads again", read ~= nil and read.command == 0x5F16)
  if read then read.processReply(read, { 1, 250, 0, 7, 0 }) end
  local children = build()
  check("a later good read draws the rows", #fields == 2, #fields)
  check("a fresh read shows no unsaved notice", not hasText(children, "Unsaved changes"))
  -- The Motor 2 row on its own, with no notice on screen yet.
  local motor2 = fields[2]
  rebuilds = 0
  if motor2 then motor2.opts.set(3) end
  check("closing the Motor 2 editor rebuilds so the unsaved notice shows",
    motor2 ~= nil and type(motor2.opts.edited) == "function" and (motor2.opts.edited() or true) and rebuilds == 1,
    rebuilds)
end

print("menu: the tile")
do
  local manifest = readFile("src/rfsuite/app/manifest.lua") or ""
  local row = string.match(manifest, "[^\n]*menuId = \"setup_esc_motors_srxl2_page\"[^\n]*")
  check("ESC & Motors carries the tile", row ~= nil)
  if row then
    -- 14 is SRXL2 in the firmware's ESC sensor protocol list from API 12.10 only; on 12.9
    -- the same number is RECORD, so the version floor has to stand beside the condition.
    check("the tile needs API 12.10", string.find(row, "minApiVersion = { 12, 0, 10 }", 1, true) ~= nil)
    check("the tile is lit by ESC telemetry protocol 14", string.find(row, "enabledWhen = \"escProto14\"", 1, true) ~= nil)
    check("the tile is locked while armed", string.find(row, "lockedWhileArmed = true", 1, true) ~= nil)
  end
  local home = readFile("src/rfsuite/ui/home.lua") or ""
  local list = string.match(home, "local ESC_PROTOCOLS = (%b{})") or ""
  check("the menu publishes escProto14", string.find(list, "%f[%d]14%f[%D]") ~= nil, list)
  check("ESC & Motors asks for the protocol where the tool is hosted",
    string.find(home, "currentMenuId == \"esc_motors_menu\"", 1, true) ~= nil)
  local registry = readFile("src/rfsuite/app/pages/init.lua") or ""
  check("the page is registered",
    string.find(registry, "setup_esc_motors_srxl2_page = definePage(\"setup/esc_motors/srxl2\")", 1, true) ~= nil)
end

print("")
if failures == 0 then
  print(string.format("all %d checks passed", checks))
  os.exit(0)
end
print(string.format("%d of %d checks FAILED", failures, checks))
os.exit(1)
