local M = {}

local Log = nil

local unpack_fn = table.unpack
local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, "not a function" end
  if type(debug) == "table" and type(debug.traceback) == "function" and type(xpcall) == "function" then
    local args = { ... }
    local function wrapped()
      return fn(unpack_fn(args))
    end
    local ok, res = xpcall(wrapped, debug.traceback)
    return ok, res
  end
  return pcall(fn, ...)
end

local function getSlot()
  _G.rfsuite = _G.rfsuite or {}
  local slot = _G.rfsuite.confirmDialogSlot
  if slot == nil then
    slot = { counter = 0 }
    _G.rfsuite.confirmDialogSlot = slot
  end
  slot.pending = slot.pending or {}
  return slot
end

-- The registry keeps lvgl.confirm callbacks for the life of the Lua state.
-- Give it trampolines that reach only the shared slot of token-keyed handlers.
local function makeTrampoline(slot, token, which)
  return function()
    local pending = slot.pending[token]
    if pending then
      local handler = pending[which]
      slot.pending[token] = nil
      pcall(handler)
    end
  end
end

-- Show a confirm dialog that behaves like legacy `lvgl.confirm` when possible.
-- ctx: { title=string, message=string, onConfirm=function, onCancel=function, onFallback=function }
-- Returns true if a UI was shown or fallback executed, false otherwise.
function M.show(ctx)
  local title = (ctx and ctx.title) or "Confirm"
  local message = (ctx and ctx.message) or ""
  local onConfirm = ctx and ctx.onConfirm
  local onCancel = ctx and ctx.onCancel
  local onFallback = ctx and ctx.onFallback

  if Log == nil then
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/log.lua", "t")
    if type(chunk) == "function" then
      local ok, mod = pcall(chunk)
      if ok and type(mod) == "table" and type(mod.emit) == "function" then
        Log = mod
      else
        Log = false
      end
    else
      Log = false
    end
  end

  if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "lvgl types: message=" .. tostring(type(lvgl and lvgl.message)), "debug") end

  local handled = false
  local function doConfirm()
    if handled then return end
    handled = true
    if type(onConfirm) == "function" then
      local ok, err = pcall(onConfirm)
      if not ok and type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "confirm handler failed: " .. tostring(err), "warn") end
    end
  end
  local function doCancel()
    if handled then return end
    handled = true
    if type(onCancel) == "function" then
      local ok, err = pcall(onCancel)
      if not ok and type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "cancel handler failed: " .. tostring(err), "warn") end
    end
  end

  -- Prefer `lvgl.confirm` when available; avoid noisy lvgl.message/dialog attempts.
  if lvgl and type(lvgl.confirm) == "function" then
    local slot = getSlot()
    slot.counter = slot.counter + 1
    local token = slot.counter
    slot.pending[token] = { confirm = doConfirm, cancel = doCancel }
    local ok, res = safeCall(function()
      return lvgl.confirm({
        title = title,
        message = message,
        confirm = makeTrampoline(slot, token, "confirm"),
        cancel = makeTrampoline(slot, token, "cancel")
      })
    end)
    if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "lvgl.confirm attempt ok=" .. tostring(ok) .. ", res=" .. tostring(res), "debug") end

    if ok and res == true then
      slot.pending[token] = nil
      doConfirm()
      return true
    end
    if ok and res == false then
      slot.pending[token] = nil
      doCancel()
      return true
    end
    -- lvgl.confirm is asynchronous: the binding registers the callbacks and returns
    -- nothing, so a nil result means the dialog is up, not that it could not be shown.
    -- The answer arrives through doConfirm/doCancel.
    if ok then
      return true
    end
    slot.pending[token] = nil
  end

  if type(onFallback) == "function" then
    pcall(onFallback, title, message)
    return true
  end

  return false
end

return M
