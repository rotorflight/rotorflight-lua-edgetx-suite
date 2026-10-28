-- Run ELRS probe arming checks from the repository root: lua5.3 bin/diagnostics/verify_elrs_probe_armed.lua
local pageDir = "src/rfsuite/app/pages/tools/diagnostics/elrs_link"
local checks, failures = 0, 0

local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print(string.format("FAIL %s: expected %s, got %s", label, tostring(expected), tostring(actual)))
  end
end

-- A broken module or host assumption must fail this scenario without hiding the others.
local function scenario(label, run)
  local ok, err = pcall(run)
  if not ok then equal(tostring(err), "no error", label .. " scenario error") end
end

local function newHost()
  local host = {
    ticks = 0, armed = false, previousArmed = false, armChanges = 0,
    rebuild = true, children = {}, pushes = {}, configRequests = 0,
    invalidations = 0, releases = 0, publishes = 0, wakeups = 0, owner = nil,
  }
  local armed = {
    isArmed = function() return host.armed end,
    isUncertain = function() return false end,
    changeCount = function() return host.armChanges end,
  }
  local provider = {
    acquire = function(owner) host.owner = owner; return true end,
    release = function(owner, dirty)
      assert(owner == "diagnostics", "unexpected ELRS lease owner")
      host.owner = nil
      host.releases = host.releases + 1
      host.lastReleaseDirty = dirty
    end,
    drain = function() return true, false end,
    invalidate = function() host.invalidations = host.invalidations + 1 end,
    publish = function() host.publishes = host.publishes + 1 end,
    currentIdentity = function() return "probe-model" end,
  }
  local telemetryApi = {
    command = 73,
    parse = function()
      return { crsf_telemetry_mode = 1, crsf_telemetry_link_rate = 500,
        crsf_telemetry_link_ratio = 4, buffer = {} }
    end,
  }
  local queue = { add = function(_, item)
    assert(item.command == 73 and not item.isWrite, "unexpected MSP write or command")
    host.configRequests = host.configRequests + 1
    item.processReply(nil, {})
  end }
  local modules = {
    ["lib/armed.lua"] = armed,
    ["lib/elrs_config.lua"] = provider,
    ["lib/crsf.lua"] = { popFrame = function() return nil end },
    ["lib/elrs_power.lua"] = { classify = function() return nil end },
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
    },
    ["ui/loading_overlay.lua"] = { append = function() error("unexpected loading overlay") end },
    ["ui/confirm_dialog.lua"] = { show = function()
      host.dialogs = (host.dialogs or 0) + 1
      return true
    end },
    ["tasks/msp/api/telemetry_config.lua"] = telemetryApi,
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
  }
  getTime = function() return host.ticks end
  -- Exercise the real task's simulated replies, paced by its 0.5 s parameter reads.
  getVersion = function() return nil, "simu" end
  crossfireTelemetryPush = function(kind, payload)
    host.pushes[#host.pushes + 1] = { kind = kind, payload = payload }
    return true
  end
  SMLSIZE, RIGHT = 0, 0
  _G.rfsuite = {
    session = { isConnected = true, telemetryType = "crsf",
      crsfTelemetryConfig = { mode = 1, linkRate = 500, linkRatio = 4 } },
    palette = { text = 1, accent = 2, accentText = 3 },
    Log = { emit = function() end },
    elrs_config = provider,
    require = function(path) return modules[path] end,
  }
  loadScript = function(path)
    local relative = assert(string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$"), path)
    if relative == "app/pages/tools/diagnostics/elrs_link/elrslink_task.lua" then
      return function()
        assert(not host.task, "task loaded twice")
        host.task = assert(loadfile(pageDir .. "/elrslink_task.lua"))()
        return host.task
      end
    end
    local module = modules[relative]
    assert(module, "unstubbed module: " .. relative)
    return function() return module end
  end
  host.page = assert(loadfile(pageDir .. "/page.lua"))()

  function host:buildIfAsked()
    if not self.rebuild then return end
    self.rebuild = false
    self.children = {}
    self.page.build({ children = self.children, x = 0, y = 0, w = 480, h = 280,
      requestRebuild = function() self.rebuild = true end })
  end

  function host:frame()
    self.ticks = self.ticks + 10
    -- ui/home.lua observes both edges, schedules a build and wakes pages only disarmed.
    if self.armed ~= self.previousArmed then
      self.armChanges = self.armChanges + 1
      self.previousArmed = self.armed
      self.rebuild = true
    end
    if not armed.isArmed() then
      self.wakeups = self.wakeups + 1
      self.page.wakeup()
    end
    self:buildIfAsked()
  end

  function host:run(seconds)
    for _ = 1, math.floor(seconds * 10) do self:frame() end
  end

  function host:arm(value)
    self.armed = value
    self:frame()
  end

  function host:buttons()
    local buttons = {}
    for _, child in ipairs(self.children) do
      if child.type == "button" then buttons[#buttons + 1] = child end
    end
    assert(#buttons == 3, "expected the three real page buttons")
    return buttons
  end

  function host:press(index)
    local button = self:buttons()[index]
    if not button.active() then return false end
    button.press()
    self:buildIfAsked()
    return true
  end

  function host:snapshot()
    assert(self.children[1].text == "Status", "missing real Status row")
    local buttons = self:buttons()
    return { status = self.children[2].text,
      active = { buttons[1].active(), buttons[2].active(), buttons[3].active() } }
  end

  function host:finished(label)
    local row = self:snapshot()
    equal(self.task.isRunning(), false, label .. ": task stopped")
    equal(row.active[1] and row.active[2] and row.active[3], true, label .. ": buttons active")
    equal(row.status ~= "Unavailable while armed", true, label .. ": armed refusal cleared")
    equal(self.owner, nil, label .. ": ELRS reader lease released")
  end

  function host:freshProbe(label)
    equal(self:press(1), true, label .. ": Probe available after disarm")
    equal(self.task.isRunning(), true, label .. ": Probe started")
    self:run(2)
    self:finished(label)
    equal(self:snapshot().status, "Probe complete", label .. ": fresh probe completed")
    local config = rfsuite.session.elrsLinkConfig
    equal(config and config.packetRate == 500 and config.telemetryRatio == 4, true,
      label .. ": real task published fresh simulated settings")
  end

  function host:noWrites(label)
    for _, frame in ipairs(self.pushes) do
      equal(frame.kind ~= 0x2D, true, label .. ": no ELRS write")
    end
    equal(not self.dialogs, true, label .. ": no armed sync confirmation")
  end

  host:buildIfAsked()
  return host
end

local function armedRow(host, label)
  local snapshot = host:snapshot()
  equal(snapshot.status, "Unavailable while armed", label .. ": armed refusal")
  equal(snapshot.active[1] and snapshot.active[2] and snapshot.active[3], true, label .. ": buttons active")
  equal(host.task.isRunning(), false, label .. ": armed probe cancelled")
end

scenario("refused presses", function()
  local host = newHost()
  host:run(2)
  host:finished("opening probe positive control")
  equal(host.publishes == 1 and #host.pushes > 0 and host.configRequests == 1, true,
    "positive control reads through the real task and requests the board config")
  host:arm(true)
  equal(host:press(2), true, "control sync button available")
  armedRow(host, "control: RF->ELRS refused while armed")
  equal(host:press(1), true, "armed Probe button available")
  equal(host:press(2), true, "sync button available after refused Probe")
  local wakes = host.wakeups
  host:run(20)
  equal(host.wakeups, wakes, "host does not wake the page while armed")
  armedRow(host, "Probe then RF->ELRS while armed, 20 s")
  host:arm(false)
  host:run(1)
  host:finished("after refused Probe and disarm")
  host:noWrites("refused presses")
end)

scenario("opening probe", function()
  local host = newHost()
  equal(host.task.isRunning(), true, "opening probe initially running")
  -- No task wakeup yet: opening reset() itself has to be cancellable.
  host:arm(true)
  local openingArmed = host:snapshot()
  equal(not host.task.isRunning() and openingArmed.active[1], true, "opening probe cancelled during arming")
  equal(openingArmed.status, "Unavailable while armed", "opening probe shows armed refusal")
  host:run(20)
  host:arm(false)
  host:run(1)
  host:finished("opening probe after disarm")
  equal(host.publishes, 0, "cancelled opening probe does not resume or publish on disarm")
  host:freshProbe("after cancelled opening probe")
  host:noWrites("opening probe")
end)

-- Cancel manual and Reload probes after they acquire the reader and begin a walk.
for _, trigger in ipairs({ "Probe", "Reload" }) do
  scenario(trigger .. " running, then armed", function()
    local host = newHost()
    host:run(2)
    if trigger == "Probe" then
      equal(host:press(1), true, "manual probe positive control")
    else
      equal(host.page.onReload(), true, "Reload keeps requesting a rebuild")
      host.rebuild = true
    end
    host:run(0.1)
    equal(host.task.isRunning() and host.owner == "diagnostics", true, trigger .. ": active walk to cancel")
    local published = host.publishes
    host:arm(true)
    armedRow(host, trigger .. " running, then armed")
    equal(host.owner == nil and host.lastReleaseDirty, true, trigger .. ": cancelled reader released dirty")
    host:run(20)
    host:arm(false)
    host:run(1)
    host:finished(trigger .. " after disarm")
    equal(host.publishes, published, trigger .. ": no partial read published after cancellation")
    host:freshProbe("after cancelled " .. trigger)
    host:noWrites(trigger)
  end)
end

-- The header refuses armed Reload before calling the page. Exercise the hook directly
-- so deferred/other callers still request board config without starting an armed probe.
scenario("armed Reload", function()
  local host = newHost()
  host:run(2)
  host:arm(true)
  local requests, invalidations = host.configRequests, host.invalidations
  equal(host.page.onReload(), true, "armed Reload keeps requesting a rebuild")
  host.rebuild = true
  host:buildIfAsked()
  equal(host.configRequests, requests + 1, "armed Reload preserves its board config request")
  equal(host.invalidations, invalidations, "armed Reload does not start a probe before cancelling it")
  armedRow(host, "Reload requested while armed")
  host:arm(false)
  host:run(1)
  host:finished("armed Reload after disarm")
  host:freshProbe("after refused Reload")
  host:noWrites("armed Reload")
end)

print(string.format("ELRS probe while armed: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
