local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/app/pages/settings/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Common = nil

local M = {}

local function ensureDeps()
  if not Common then
    Common = loadModule("common.lua")
  end
end

function M.build(ctx)
  ensureDeps()
  Common.buildSimplePage(ctx, "settings_activelook", "section_activelook", "ActiveLook", {
    { labelKey = "style", labelFallback = "Style", valueKey = "value_style", valueFallback = "MODERN" },
    { labelKey = "icon_pack", labelFallback = "Icon Pack", valueKey = "value_icon_pack", valueFallback = "RF SUITE" },
    { labelKey = "contrast", labelFallback = "Contrast", valueKey = "value_contrast", valueFallback = "HIGH" },
    { labelKey = "highlight", labelFallback = "Highlight", valueKey = "value_highlight", valueFallback = "AMBER" },
    { labelKey = "animations", labelFallback = "Animations", valueKey = "value_animations", valueFallback = "ON", withArrow = false }
  })
end

function M.onClose()
  Common = nil
end

return M
