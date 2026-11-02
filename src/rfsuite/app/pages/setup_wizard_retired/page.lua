-- What Configuration > Wizards > Full initial setup opens while the setup assistant is being
-- replaced. The assistant itself (app/pages/setup_wizard/) is no longer reachable from any menu;
-- this page says so instead of opening it. It reads nothing from the flight controller and
-- writes nothing anywhere.
local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
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
  if not t then t = Common and Common.pageT("setup_wizard") or nil end
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

function M.getHeaderActions()
  return {
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  local children = ctx.children
  local i18n = ctx.i18n

  children[#children + 1] = {
    type = "label",
    x = ctx.x + 10, y = ctx.y + 10, w = ctx.w - 20,
    text = pageText(i18n, "retired_notice", "The setup assistant is being replaced by a new guided setup in an upcoming version and is no longer available in this one."),
    color = Palette.text,
    font = MIDSIZE
  }
end

function M.onClose()
  Common = nil
  t = nil
end

return M
