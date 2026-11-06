-- Shared Power page choices and editor limits. Wire codecs stay in the MSP APIs.
local M = {
  capacity = { min = 0, max = 40000 },
  cellCount = { min = 0, max = 24 }
}
function M.sourceOptions(i18n, selected, version, ApiVersion)
  local options = {
    { value = 0, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_none") or "NONE") },
    { value = 1, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_adc") or "ADC") },
    { value = 2, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_esc") or "ESC") },
    { value = 3, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_fbus") or "FBUS") }
  }
  -- The CRSF meter source (an external CRSF sensor on a port set to CRSF Sensors) reached the
  -- firmware while the API was already at 12.10. Without a known version it is not offered;
  -- a value already stored still shows below as Unknown and is kept on save.
  if version and ApiVersion.isAtLeast(version, {12, 0, 10}) then
    options[#options+1] = { value = 4, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_crsf") or "CRSF") }
  end
  for _, option in ipairs(options) do if option.value == selected then return options end end
  if type(selected) == "number" then
    options[#options+1] = { value = selected,
      label = (i18n and i18n.t and i18n.t("app.pages.setup_power_sources.source_unknown") or "Unknown") .. " (" .. selected .. ")" }
  end
  return options
end
function M.modeOptions(i18n)
  return {
    { value = 0, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.mode_off") or "OFF (LOCAL)") },
    { value = 1, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.mode_voltage") or "VOLTAGE") },
    { value = 2, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.mode_current") or "CURRENT") },
    { value = 3, label = (i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.mode_combined") or "COMBINED") }
  }
end
function M.capacityText(value) return tostring(value) .. " mAh" end
function M.reading(value, divisor, unit) return string.format("%.2f %s", value / divisor, unit) end
function M.needsVoltage(mode) return mode == 1 or mode == 3 end
-- Matches the SmartFuel entry in app/manifest.lua; Battery has no version gate.
function M.supportsSmartFuel(version, ApiVersion)
  return ApiVersion.isAtLeast(version, {12, 0, 9})
end
return M
