-- Keep main.lua lightweight; it is loaded for all widgets at boot.
local name = "RFSuite"

if lvgl == nil then
  return {
    name = name,
    options = {},
    create = function() end,
    refresh = function()
      lcd.drawText(10, 10, "LVGL support required", COLOR_THEME_WARNING)
    end,
  }
end

local function logCreateFailure(err)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.widget", "dashboard not created: " .. tostring(err), "error")
  end
  local fault = type(_G) == "table" and _G.rfsuite and _G.rfsuite.logFault
  if type(fault) == "function" then pcall(fault, "widget.create", err) end
end

local function create(zone, options)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local requireChunk = loadScript("/SCRIPTS/RFSUITE/core/lib/require.lua", mode)
  if requireChunk then
    pcall(requireChunk)
  end
  local appChunk = loadScript("/WIDGETS/rfsuite/app.lua", mode)
  if not appChunk then
    appChunk = loadScript("/SCRIPTS/RFSUITE/core/widgets/dashboard/runtime.lua", mode)
  end
  if not appChunk then return nil end

  local ok, res = pcall(appChunk, zone, options)
  if not ok then logCreateFailure(res) end
  if ok and res ~= nil then
    if type(res) == "function" then
      local okFn, widget = pcall(res, zone, options)
      if okFn then return widget end
      logCreateFailure(widget)
    elseif type(res) == "table" then
      if type(res.new) == "function" then
        local okNew, widget = pcall(res.new, zone, options)
        if okNew then return widget end
        logCreateFailure(widget)
      else
        return res
      end
    end
  end
  return nil
end

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  return 0
end

local function isCpuLimitError(err)
  local fn = type(_G) == "table" and _G.rfsuite and _G.rfsuite.isCpuLimitError
  if type(fn) == "function" then return fn(err) end
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

-- A caught error, on its way to the card, so the reason a pass failed outlives the pass. The
-- module is loaded here rather than at the top of the file because this one is read for every
-- widget at boot and a fault is not the common case; lib/log_sink.lua then makes the same check
-- again itself and writes nothing while the option is off.
--
-- `work`, where given, is the work class the dashboard last named for the pass (its `_passWork`,
-- the word its `long pass:` and `pass gap` lines carry), so the line says where the pass stopped and
-- not only why. The dashboard names it part way into a pass, so a stop before that point names the
-- previous pass's work; hence "last work". Only the log line carries it: the card's fault record
-- keeps the error text as it was.
local function logFault(context, err, work)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emit) == "function" then
    local line = tostring(context) .. " stopped: " .. tostring(err)
    if work ~= nil then line = line .. " (last work " .. tostring(work) .. ")" end
    pcall(Log.emit, "rfsuite.widget", line, "error")
  end

  local fn = type(_G) == "table" and _G.rfsuite and _G.rfsuite.logFault
  if type(fn) == "function" then
    pcall(fn, context, err)
    return
  end

  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local general = prefs and prefs.general
  if type(general) ~= "table" or general.log_to_card ~= true then return end

  local requireModule = _G.rfsuite and _G.rfsuite.require
  if type(requireModule) ~= "function" then return end

  local okLoad, sink = pcall(requireModule, "lib/log_sink.lua")
  if okLoad and type(sink) == "table" and type(sink.fault) == "function" then
    pcall(sink.fault, context, err)
  end
end

local function update(widget, options)
  if widget and widget.update then
    local ok, err = pcall(widget.update, widget, options)
    if not ok then
      logFault("widget.update", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = nowSeconds() + 0.8
      end
    end
  end
end

-- A widget that is holding something the radio must not be left holding, given the chance to let
-- go while it is backed off.
--
-- A back-off is not a pause. The dashboard's in-flight tuning overlay drives the flight
-- controller by writing two of the radio's global variables, and every path that takes them back
-- to zero lives inside widget.refresh or widget.background -- neither of which is called for the
-- 1.2 s below. Left standing, the flight controller goes on stepping that parameter roughly five
-- times a second with nothing driving it. The widget installs this closure itself and it does
-- nothing at all when there is nothing standing; the pcall is because a widget that has just
-- failed must not be able to fail here as well.
local function letGoWhileBackedOff(widget)
  local release = widget and widget._inflightPanic
  if type(release) == "function" then pcall(release) end
end

local function refresh(widget, event, touchState)
  if widget and widget.refresh then
    local now = nowSeconds()
    local backoffUntil = tonumber(widget._cpuBackoffUntil) or 0
    if backoffUntil > 0 and now < backoffUntil then
      letGoWhileBackedOff(widget)
      return
    end

    -- Read before the call: a job step that raises has its job dropped by the dashboard before the
    -- error reaches this point.
    local jobBefore = widget._job
    local ok, err = pcall(widget.refresh, widget, event, touchState)
    if not ok then
      logFault("widget.refresh", err, widget._passWork)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = now + 1.2
        letGoWhileBackedOff(widget)
      end
      -- Clear any pending job so the widget cannot be pinned in the JOB branch
      -- for ever when a job step raises and unwinds past refresh (see #280).
      --
      -- The tree is given up only when a job was pending, before the pass or after it: that is
      -- the case where what stands on screen may be half built. A pass that stopped with no job
      -- in front of it was reading values onto a finished tree, which is still whole; clearing
      -- `built` there made the next pass build the same surface again -- the standby screen after
      -- a stop on connect, for one -- for nothing but the memory a rebuild costs. A path that takes
      -- a tree down outside a job clears `built` itself before it does.
      local job = jobBefore or widget._job
      widget._job = nil
      if job ~= nil then
        widget.built = false
        local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
        if type(Log) == "table" and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.widget", "rebuild: after a stopped pass, job " .. tostring(job.kind), "debug")
        end
      end
    end
  end
end

-- The back-off is honoured here as well as in refresh(), because this is the path that can
-- loop. A background pass that hits the instruction limit is called again on the very next
-- host cycle with the same work in front of it, so a flag that is only read by refresh()
-- suppresses the pass the pilot is looking at and leaves the one that failed running. The
-- release is for the same reason it is in refresh(): a back-off is not a pause, and whatever
-- the widget was holding when it failed must not be left standing for the duration.
local function background(widget)
  if widget and widget.background then
    local now = nowSeconds()
    local backoffUntil = tonumber(widget._cpuBackoffUntil) or 0
    if backoffUntil > 0 and now < backoffUntil then
      letGoWhileBackedOff(widget)
      return
    end

    local ok, err = pcall(widget.background, widget)
    if not ok then
      logFault("widget.background", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = now + 0.8
        letGoWhileBackedOff(widget)
      end
    end
  end
end

return {
  useLvgl = true,
  name = name,
  options = {},
  create = create,
  update = update,
  refresh = refresh,
  background = background,
}
