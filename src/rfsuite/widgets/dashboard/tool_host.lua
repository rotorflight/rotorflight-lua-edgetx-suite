-- The suite's tool, opened from the dashboard widget and run inside it.
--
-- EdgeTX gives a widget no way to start a tool script, so the dashboard does not start one: it
-- loads `ui/home.lua` into its own Lua state and drives it from `widget.refresh` for as long as
-- it is open. `ui/home.lua` returns `{ init, run }`, the same contract the radio drives a tool
-- script with, and paints itself with lvgl.clear() and lvgl.build(), so a fullscreen widget can
-- carry it unchanged. Opened with `init({ hosted = true })`, it leaves alone what the dashboard
-- in this state already owns -- the module cache, the event runner, the card sink, the audio
-- engine and the global table -- and it shares the dashboard's MSP runtime rather than bringing
-- a second one, so there is one client on the link and the connect chain is not run again.
--
-- Two things differ from the tool script, and both are the radio's rather than this file's:
--
--   * A widget call is stopped at the instruction limit; the tool script, which a colour radio
--     runs in a Lua state of its own, is not. EdgeTX raises that stop once per call and lets the
--     rest of the call run, so it is caught by the innermost pcall around the code it lands in.
--     For a page that builds a lot that is the build guard in ui/home.lua, which builds the page
--     again on the next pass, a few passes in a row at most, before it shows the page as one that
--     cannot be drawn: a build that fits in what a pass leaves it completes there, and a build
--     that is above the limit on its own does not open here at all. A page's wakeup is stopped the same way
--     and called again on the next pass, so a page that spreads its work over its wakeups has to
--     keep each of them within what a pass leaves. A stop that escapes ui/home.lua reaches the
--     step below, which runs the tool again on the next pass and gives up after CPU_GIVE_UP in a
--     row; a raise that escapes that catch reaches the widget's entry point, which backs off as
--     it does for any other pass (src/widgets/rfsuite/main.lua).
--   * The tool's modules stay in this state's module cache after the tool is closed. The
--     dashboard's own modules are in the same cache, so the cache cannot be emptied; only the
--     entries the dashboard never uses -- the pages and the tool's interface -- are dropped.
--
-- What the tool loads is loaded as the tool script loads it, because the tool script's loader is
-- not the radio's: src/main.lua puts a wrapper over loadScript that reads the bytecode beside a
-- file when it is current and keeps a shared module's chunk for as long as the tool runs. The
-- pages load themselves and most of what they use with loadScript(path, "t") and rely on that
-- wrapper; without it every page here, and every file it loads that way, would be compiled from
-- source on every visit, and the bytecode the radio writes beside each file never read back. The
-- same loader is therefore put in place while the tool is open and taken away when it closes
-- (see installLoader below).
--
-- The tool is closed by its own closing sequence wherever that can still run: the back key at
-- the top of its menu, the model arming, and fullscreen being left. Arming closes it because
-- while it is open it runs in place of the dashboard's pass, and the dashboard's pass is what
-- makes the callouts. A widget sent to the background cannot paint and is dropped at once; its
-- pages are still released on the way out (see finish). A save the tool started is not ended by
-- the close: one that restarts the flight controller is dismissed as Back dismisses it (see
-- leaveSave), and the dashboard drives it on to its end (driveLeftSave in
-- widgets/dashboard/runtime.lua).
--
-- Loaded on the first press that opens the tool, never on a pass that does not.

local M = {}

local BASE_PATH = _G.rfsuite.paths.core .. "/"
local HOME_PATH = BASE_PATH .. "ui/home.lua"

-- The module cache entries the tool brings and the dashboard does not use. Dropped on close.
local TOOL_PREFIXES = { BASE_PATH .. "app/", BASE_PATH .. "ui/" }

-- How many instruction-limit stops in a row a phase may take before the tool is given up on. Only
-- a stop that escapes ui/home.lua counts here (its page build and page wakeup catch their own); a
-- phase that is stopped every time is not going to finish, and retrying it for ever would leave
-- the widget showing nothing.
local CPU_GIVE_UP = 12

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or (BASE_PATH .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")

local function hostLog(msg, level)
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.widget", msg, level or "info")
  end
end

-- A transition, with what this state and the radio have left at that moment: the tool runs in
-- the dashboard's Lua state, so the line when it is up and the line after it has closed say what
-- the visit took and what it left behind; the dashboard's own state line is the reading before.
local function hostLogTransition(msg)
  if Log and type(Log.resources) == "function" then
    local ok, text = pcall(Log.resources)
    if ok and type(text) == "string" then msg = msg .. ", " .. text end
  end
  hostLog(msg)
end

-- A step of an open or a close. Not on a pass of the running tool; the memory figures are asked
-- for only when the line will be written.
local function hostStep(msg)
  if Log and type(Log.wanted) == "function" and Log.wanted("debug") then
    pcall(Log.emit, "rfsuite.widget.tool", msg .. ", " .. Log.resources(), "debug")
  end
end

local function isCpuLimit(err)
  local fn = _G.rfsuite and _G.rfsuite.isCpuLimitError
  if type(fn) == "function" then return fn(err) == true end
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

local function modelArmed()
  local Armed = requireModule("lib/armed.lua")
  return type(Armed) == "table" and type(Armed.isArmed) == "function" and Armed.isArmed() == true
end

-- The tool's work runs under the widget's event context: the MSP queue then bounds its loops by
-- count rather than by time, which is what a call that can be stopped needs, and the event runner
-- stays on the one task list this state has already worked through.
local function callInWidgetContext(fn, ...)
  local root = _G.rfsuite
  root.session = root.session or {}
  local previous = root.session.event_context
  root.session.event_context = "widget"
  local ok, result = pcall(fn, ...)
  root.session.event_context = previous
  return ok, result
end

-- A page's own module file. The page registry holds the module for as long as it wants it, so
-- its chunk is not kept: kept, the bytecode of every page opened would stay until the tool
-- closes. The same rule as the tool script's loader (src/main.lua).
local function isPageModule(path)
  return string.sub(path, -9) == "/page.lua" and string.find(path, "/app/pages/", 1, true) ~= nil
end

-- The tool script's loader, for as long as the tool is open: the suite's load mode in place of
-- the one a caller passed, and every chunk but a page's kept until the tool closes. The global
-- table of this state is shared with every other widget on the radio, so only the suite's own
-- files go through it; any other path reaches the radio's loader exactly as it was asked for.
-- A copy left behind once the tool has closed -- held by a caller, or under a wrapper another
-- widget put over it -- passes every call through.
local function installLoader(host)
  local original = _G.loadScript
  local chunks = {}
  local function load(path, mode)
    if host.loader ~= load or type(path) ~= "string" or string.sub(path, 1, #BASE_PATH) ~= BASE_PATH then
      return original(path, mode)
    end
    local chunk = chunks[path]
    if chunk then return chunk end
    local root = _G.rfsuite
    local err
    chunk, err = original(path, (root and root.loadMode) or mode)
    if chunk and not isPageModule(path) then chunks[path] = chunk end
    return chunk, err
  end
  host.loader = load
  host.chunks = chunks
  host.originalLoadScript = original
  _G.loadScript = load
end

-- Puts back the function installLoader replaced, unless something has been put over it since;
-- the copy then passes through. The kept chunks are let go either way.
local function removeLoader(host)
  local load = host.loader
  if load == nil then return end
  host.loader = nil
  if _G.loadScript == load then
    _G.loadScript = host.originalLoadScript
  end
  local chunks = host.chunks
  host.chunks = nil
  for path in pairs(chunks) do
    chunks[path] = nil
  end
end

local function dropToolModules()
  local modules = _G.rfsuite and _G.rfsuite.modules
  if type(modules) ~= "table" then return 0 end
  local dropped = 0
  for path in pairs(modules) do
    for i = 1, #TOOL_PREFIXES do
      local prefix = TOOL_PREFIXES[i]
      if string.sub(path, 1, #prefix) == prefix then
        modules[path] = nil
        dropped = dropped + 1
        break
      end
    end
  end
  return dropped
end

-- A save that restarts the flight controller holds the page, and Back on it dismisses it once the
-- settings are stored: the save then finishes without a screen and reports when its page is entered
-- again. The close takes the screen away without that press, so it dismisses the save the same way
-- (tasks/msp/save_pipeline.lua, dismissWhenStored), and the dashboard drives it to its end
-- (driveLeftSave in widgets/dashboard/runtime.lua). A save that does not restart the flight
-- controller is left as Back leaves it, and so is an outcome already on screen. Asked when a close
-- this host starts begins (fullscreen left, the model armed), since a reply can end the save during
-- the closing sequence, and again in finish for every way out, the pilot's own close and those that
-- skip that sequence included.
local function toSavePipeline(name)
  local pipeline = _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.savePipeline
  if type(pipeline) ~= "table" or pipeline.run == nil then return end
  local SavePipeline = requireModule("tasks/msp/save_pipeline.lua")
  if type(SavePipeline) == "table" and type(SavePipeline[name]) == "function" then
    pcall(SavePipeline[name])
  end
end

local function leaveSave()
  toSavePipeline("dismissWhenStored")
end

-- The tool opened again while such a dismissal still waits for the EEPROM commit shows the run
-- once more, so the request is withdrawn (reclaim) before the tool's first build: the save then
-- reports in the notice on this screen, whatever page the tool opens on, instead of being held for
-- its page.
local function reclaimSave()
  toSavePipeline("reclaim")
end

-- Hand the screen and the globals back to the dashboard. Safe to run in any phase.
local function finish(widget, reason)
  local host = widget._toolHost
  widget._toolHost = nil
  if host == nil then return end

  -- The pages first, while everything their onClose may touch is still in place: a page switches
  -- its override off or rolls back a live change only there, and a tool dropped without the
  -- closing sequence -- abandoned, given up at the instruction limit, or stopped by an error --
  -- would otherwise leave that change on the flight controller with nothing in this state able to
  -- take it back. The writes it queues are sent by the dashboard's own MSP tick. A tool that went
  -- through its closing sequence has released them already, and this finds nothing to do.
  local home = host.home
  if type(home) == "table" and type(home.releasePages) == "function" then
    callInWidgetContext(home.releasePages)
  end

  leaveSave()

  removeLoader(host)

  local MspRuntime = requireModule("tasks/msp/runtime.lua")
  if MspRuntime and type(MspRuntime.detach) == "function" then
    pcall(MspRuntime.detach, "tool")
  end
  -- The tool names the queue's default client after each page it opens and after itself on its
  -- way out. Left so, a request the dashboard queues without naming a client would be filed under
  -- the tool's name, and the next close of the tool would clear it from the queue.
  if host.snapshot and MspRuntime and type(MspRuntime.setDefaultClient) == "function" then
    pcall(MspRuntime.setDefaultClient, host.defaultClient or "default")
  end

  -- Loading ui/home.lua replaces the save function and init() replaces the preferences table.
  -- The dashboard reads both through the global table, so the values it had are put back; a
  -- setting the tool saved reaches the dashboard through its own reload of the settings file.
  local root = _G.rfsuite
  if root and host.snapshot then
    root.preferences = host.preferences
    root.savePreferences = host.savePreferences
  end

  -- A dialog still on screen would otherwise keep its handlers, and through them
  -- the closed tool, in the widget's Lua state. Clear directly without loading a module.
  if root and root.confirmDialogSlot then
    root.confirmDialogSlot.pending = {}
  end

  local dropped = dropToolModules()
  hostStep("tool modules dropped: " .. tostring(dropped))

  widget._job = nil
  widget.built = false
  widget.renderKey = nil
  widget._cachedFullscreenKey = nil
  if collectgarbage then collectgarbage("collect") end
  hostLogTransition("tool closed (" .. tostring(reason) .. ")")
end

--- Ask for the tool to be opened. The work is done by the next pass of the widget, not by the
--- press: a press arrives in the middle of a pass whose budget is already partly spent. Refused
--- while the model is armed.
--
-- `landing`, where given, is the menuId of the page the tool opens on instead of its menu
-- (`init({ hosted = true, landing = ... })` in ui/home.lua); the back key there closes the tool.
function M.request(widget, landing)
  if widget._toolHost ~= nil then return false end
  if modelArmed() then
    hostLog("tool not opened: the model is armed", "warn")
    return false
  end
  hostStep("tool asked for, landing " .. tostring(landing))
  widget._toolHost = { phase = "load", cpuHits = 0, landing = landing }
  widget.built = false
  widget.renderKey = nil
  return true
end

function M.isOpen(widget)
  return widget._toolHost ~= nil
end

--- Drop the tool without its closing sequence, for a widget that can no longer paint it. Its
--- pages are released all the same (see finish).
function M.abandon(widget, reason)
  finish(widget, reason or "abandoned")
end

local function stopped(widget, host, err, phase)
  if isCpuLimit(err) then
    host.cpuHits = host.cpuHits + 1
    hostLog("tool " .. phase .. " stopped at the instruction limit (" .. host.cpuHits .. "/" .. CPU_GIVE_UP .. ")", "warn")
    if host.cpuHits >= CPU_GIVE_UP then
      finish(widget, phase .. " stopped at the instruction limit " .. host.cpuHits .. " times")
    end
    return
  end
  hostLog("tool " .. phase .. " failed: " .. tostring(err), "error")
  finish(widget, phase .. " failed")
end

local function loadStep(widget, host)
  local root = _G.rfsuite
  if not host.snapshot then
    host.preferences = root.preferences
    host.savePreferences = root.savePreferences
    local MspRuntime = requireModule("tasks/msp/runtime.lua")
    local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
    local queue = type(runtimeState) == "table" and runtimeState.queue or nil
    host.defaultClient = type(queue) == "table" and queue.defaultClient or nil
    host.snapshot = true
  end
  if host.loader == nil then installLoader(host) end
  local chunk, err = loadScript(HOME_PATH, root.loadMode or "bt")
  if not chunk then
    hostLog("tool not opened: " .. tostring(err), "error")
    finish(widget, "load failed")
    return
  end
  local ok, home = pcall(chunk)
  if not ok then return stopped(widget, host, home, "load") end
  if type(home) ~= "table" or type(home.init) ~= "function" or type(home.run) ~= "function" then
    hostLog("tool not opened: ui/home.lua is not a tool", "error")
    finish(widget, "load failed")
    return
  end
  hostStep("tool loaded")
  host.home = home
  host.phase = "init"
  host.cpuHits = 0
end

local function initStep(widget, host)
  reclaimSave()
  local ok, err = callInWidgetContext(host.home.init, { hosted = true, landing = host.landing })
  if not ok then return stopped(widget, host, err, "init") end
  host.phase = "run"
  host.cpuHits = 0
  hostLogTransition("tool opened")
end

local function runStep(widget, host, event, touchState)
  local home = host.home
  -- Fullscreen has been left (a pass without an event), or the model has armed: the tool's own
  -- closing sequence takes it down over the passes that follow, writes included.
  if not host.closing and (event == nil or modelArmed()) then
    host.closing = true
    hostStep(event == nil and "tool closing: fullscreen was left" or "tool closing: the model armed")
    leaveSave()
    if type(home.requestClose) == "function" then pcall(home.requestClose) end
  end
  local ok, result = callInWidgetContext(home.run, event, touchState)
  if not ok then return stopped(widget, host, result, "run") end
  host.cpuHits = 0
  if result == 2 then finish(widget, host.closing and "closed by the widget" or "closed by the pilot") end
end

--- One pass of the open tool, in place of the dashboard's own. Returns nothing; the tool is
--- closed, and the dashboard rebuilt, once `M.isOpen(widget)` is false again.
function M.step(widget, event, touchState)
  local host = widget._toolHost
  if host == nil then return end
  if host.phase ~= "run" and (event == nil or modelArmed()) then
    -- Not up yet, so there is no page to release and nothing queued: no closing sequence.
    finish(widget, "left before it was up")
    return
  end
  if host.phase == "load" then
    loadStep(widget, host)
  elseif host.phase == "init" then
    initStep(widget, host)
  else
    runStep(widget, host, event, touchState)
  end
end

return M
