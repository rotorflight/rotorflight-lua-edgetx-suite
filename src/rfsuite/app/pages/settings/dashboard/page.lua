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
  Common.buildSimplePage(ctx, "settings_dashboard", "section_dashboard", "Dashboard", {
    { labelKey = "theme", labelFallback = "Theme", valueKey = "value_theme", valueFallback = "DEFAULT" },
    { labelKey = "layout", labelFallback = "Layout", valueKey = "value_layout", valueFallback = "GRID" },
    { labelKey = "show_labels", labelFallback = "Show Labels", valueKey = "value_show_labels", valueFallback = "ON" },
    { labelKey = "widget_spacing", labelFallback = "Widget Spacing", valueKey = "value_widget_spacing", valueFallback = "MEDIUM" },
    { labelKey = "refresh_rate", labelFallback = "Refresh Rate", valueKey = "value_refresh_rate", valueFallback = "10Hz", withArrow = false }
  })
end

function M.onClose()
  Common = nil
end

return M
