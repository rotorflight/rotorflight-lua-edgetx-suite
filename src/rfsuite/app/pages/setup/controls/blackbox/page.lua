local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Common = nil
local t = nil

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not t then t = Common and Common.pageT("setup_controls") or nil end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

function M.wakeup(ctx)
  ensureDeps()
end

function M.getHeaderActions()
  return {
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  -- Sync header title
  local title = pageText(i18n, "blackbox", "Blackbox")
  if type(ctx.syncHeaderTitle) == "function" then
    ctx.syncHeaderTitle(title, M.getHeaderActions())
  end

  children[#children + 1] = {
    type = "label",
    x = x + 10, y = y + 10,
    text = "Work in progress...",
    color = Palette.text,
    font = MIDSIZE
  }
end

function M.onClose()
  Common = nil
  t = nil
end

return M
