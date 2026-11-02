local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

-- Every page under Settings > Audio > Events is built here. The pages share one schema, one
-- preference table (`preferences.audio_events`), one save path and one set of translations;
-- what differs between them is which rows a page draws and which keys it writes. So each
-- category's page.lua names its category and nothing else, and lib/audio.lua goes on reading
-- one flat table.

-- The governor states in the order the firmware numbers them (govState_e, 0..9). lib/audio.lua
-- keeps the same order in its file map and in the preference keys it consults.
local GOVERNOR_STATES = {
  { key = "governor_state_off",      labelKey = "governor_state_off",      labelFallback = "Off" },
  { key = "governor_state_idle",     labelKey = "governor_state_idle",     labelFallback = "Idle" },
  { key = "governor_state_spoolup",  labelKey = "governor_state_spoolup",  labelFallback = "Spool-up" },
  { key = "governor_state_recovery", labelKey = "governor_state_recovery", labelFallback = "Recovery" },
  { key = "governor_state_active",   labelKey = "governor_state_active",   labelFallback = "Active" },
  { key = "governor_state_thr_off",  labelKey = "governor_state_thr_off",  labelFallback = "Throttle off" },
  { key = "governor_state_lost_hs",  labelKey = "governor_state_lost_hs",  labelFallback = "Lost headspeed" },
  { key = "governor_state_autorot",  labelKey = "governor_state_autorot",  labelFallback = "Autorotation" },
  { key = "governor_state_bailout",  labelKey = "governor_state_bailout",  labelFallback = "Bailout" },
  { key = "governor_state_bypass",   labelKey = "governor_state_bypass",   labelFallback = "Bypass" },
}

-- ─── Config schema ───────────────────────────────────────────────────────────
-- Single source of truth for all persisted audio event settings. `section` names the page
-- that draws and saves an entry: a save writes its own section's keys and leaves the rest of
-- the table as the other pages left it. A numeric entry carries the range it is valid in, so
-- that the clamp applied on load and the bounds of the control on screen cannot drift apart.

local CONFIG_SCHEMA = {
  { key = "arming_flags",      type = "bool", default = true,  section = "arming" },
  { key = "governor_state",    type = "bool", default = true,  section = "governor" },
  { key = "voltage_alert",     type = "bool", default = true,  section = "voltage" },
  -- Seconds the pack voltage has to stay below the warning line before the alert speaks. 0 is
  -- the behaviour this setting was added to, where the first sample under the line announces.
  { key = "voltage_hold",      type = "number", default = 2, min = 0, max = 10, section = "voltage" },
  -- Millivolts per cell above the warning line that the pack has to come back to before the
  -- alert counts as cleared, so the number means the same on every pack, as the line does.
  { key = "voltage_reset",     type = "number", default = 100, min = 50, max = 500, section = "voltage" },
  { key = "main_power_lost",   type = "bool", default = false, section = "voltage" },
  -- How every flight-pack voltage is spoken: 0 the pack's voltage, 1 the voltage per cell.
  -- It covers the low-voltage alert, the main pack coming back and the pack check on connect;
  -- not the BEC voltage spoken with Main Power Lost, which is not the flight pack's.
  { key = "voltage_announce",  type = "number", default = 0, min = 0, max = 1, section = "voltage" },
  -- Whether an alert repeats and whether it buzzes belong to a CATEGORY rather than to one
  -- alert: this page is where the pilot switches its alerts on, so it is where they say how
  -- those alerts behave. A repeat of 0 is "for as long as the condition holds", which is what
  -- every alert did before these settings existed, and the haptic defaults to on because most
  -- of the alerts they cover already buzzed with no way of stopping them. lib/audio.lua holds
  -- the map from an alert to the category it takes these two from.
  { key = "voltage_repeat",    type = "number", default = 0, min = 0, max = 10, section = "voltage" },
  { key = "voltage_haptic",    type = "bool", default = true,  section = "voltage" },
  { key = "pid_profile",       type = "bool", default = true,  section = "profiles" },
  { key = "rate_profile",      type = "bool", default = true,  section = "profiles" },
  { key = "esc_temperature",   type = "bool", default = false, section = "esc" },
  -- `scope = "model"` marks a value that describes the aircraft rather than the radio:
  -- the ESC's temperature limit is a property of one model's hardware. It is read and
  -- written through the per-model store whenever there is one, and falls back to the
  -- global file on a radio that has none.
  { key = "esc_threshold",     type = "number", default = 90, min = 60, max = 300, scope = "model", section = "esc" },
  -- The level above the warning one, where the alert vibrates as well. The same aircraft's
  -- hardware as the warning level, so the same scope and range.
  { key = "esc_critical",      type = "number", default = 110, min = 60, max = 300, scope = "model", section = "esc" },
  { key = "mcu_temperature",   type = "bool", default = false, section = "esc" },
  -- No `scope = "model"`, unlike the ESC levels above: the flight controller's MCU is the
  -- same silicon with the same rating in every aircraft, so a copy of these levels per model
  -- would be one more place to keep in step and nothing else.
  { key = "mcu_threshold",     type = "number", default = 80, min = 40, max = 150, section = "esc" },
  -- The current as a percentage of the speed controller's limit (Setup > Power > Preferences).
  -- Radio-wide: the load is already a share of the model's own limit, so the same percentages
  -- mean the same in every model. Above 100 is a load past the limit, which is why the range is.
  { key = "esc_load",          type = "bool", default = false, section = "esc" },
  { key = "esc_load_warn",     type = "number", default = 80, min = 10, max = 200, section = "esc" },
  { key = "esc_load_critical", type = "number", default = 100, min = 10, max = 200, section = "esc" },
  -- Seconds the load has to stay at or above a level before it is spoken.
  { key = "esc_load_hold",     type = "number", default = 5, min = 0, max = 30, section = "esc" },
  { key = "mcu_critical",      type = "number", default = 95, min = 40, max = 150, section = "esc" },
  { key = "esc_repeat",        type = "number", default = 0, min = 0, max = 10, section = "esc" },
  { key = "esc_haptic",        type = "bool", default = true,  section = "esc" },
  { key = "lq_alert",          type = "bool", default = false, section = "link" },
  { key = "lq_warn",           type = "number", default = 70, min = 1, max = 100, section = "link" },
  { key = "lq_critical",       type = "number", default = 50, min = 1, max = 100, section = "link" },
  { key = "telemetry_lost",    type = "bool", default = false, section = "link" },
  -- The TX power alert: the transmitter's power as a share of its maximum, which rises as the link
  -- weakens, so its levels are lines the share climbs to and the critical one is the higher. The
  -- maximum is the module's own Max Power, read from the module; `tpwr_limit` puts `tpwr_max` in its
  -- place. All of it is the transmitter's rather than the aircraft's, so none of it is per model.
  { key = "tpwr_alert",        type = "bool", default = false, section = "link" },
  { key = "tpwr_warn",         type = "number", default = 60, min = 1, max = 100, section = "link" },
  { key = "tpwr_critical",     type = "number", default = 85, min = 1, max = 100, section = "link" },
  { key = "tpwr_hold",         type = "number", default = 2, min = 0, max = 10, section = "link" },
  { key = "tpwr_limit",        type = "bool", default = false, section = "link" },
  -- No range: a choice out of TX_POWER_MAX_VALUES below, the power steps a module offers.
  { key = "tpwr_max",          type = "number", default = 100, section = "link" },
  -- The signal headroom over the air rate's sensitivity floor, in percent of the scale
  -- lib/link_rates.lua defines (LinkRates.headroom): RSSI at the receiver, Downlink at the
  -- transmitter module. Each has its own switch, its own pair of levels and its own hold, the
  -- seconds a level has to hold before it is spoken.
  { key = "rssi_alert",        type = "bool", default = false, section = "link" },
  { key = "rssi_warn",         type = "number", default = 15, min = 1, max = 100, section = "link" },
  { key = "rssi_critical",     type = "number", default = 8, min = 1, max = 100, section = "link" },
  { key = "rssi_hold",         type = "number", default = 2, min = 0, max = 10, section = "link" },
  { key = "trss_alert",        type = "bool", default = false, section = "link" },
  { key = "trss_warn",         type = "number", default = 15, min = 1, max = 100, section = "link" },
  { key = "trss_critical",     type = "number", default = 8, min = 1, max = 100, section = "link" },
  { key = "trss_hold",         type = "number", default = 2, min = 0, max = 10, section = "link" },
  -- The signal-to-noise ratio at the receiver (SNR) and at the transmitter module (Downlink SNR),
  -- in percent of the window between the air rate's two dynamic-power thresholds
  -- (LinkRates.snrPercent): 0 is the threshold at which ExpressLRS asks for more power, so the
  -- critical level may be 0.
  { key = "rsnr_alert",        type = "bool", default = false, section = "link" },
  { key = "rsnr_warn",         type = "number", default = 30, min = 0, max = 100, section = "link" },
  { key = "rsnr_critical",     type = "number", default = 0, min = 0, max = 100, section = "link" },
  { key = "rsnr_hold",         type = "number", default = 2, min = 0, max = 10, section = "link" },
  { key = "tsnr_alert",        type = "bool", default = false, section = "link" },
  { key = "tsnr_warn",         type = "number", default = 30, min = 0, max = 100, section = "link" },
  { key = "tsnr_critical",     type = "number", default = 0, min = 0, max = 100, section = "link" },
  { key = "tsnr_hold",         type = "number", default = 2, min = 0, max = 10, section = "link" },
  -- Telemetry dropouts: spoken when the flight controller's frames are missed `dropouts_count`
  -- times within `dropouts_window` seconds. The window starts at 4 s because the skipped-frame
  -- counter it watches is published every 2 s.
  { key = "dropouts_alert",    type = "bool", default = false, section = "link" },
  { key = "dropouts_count",    type = "number", default = 3, min = 1, max = 50, section = "link" },
  { key = "dropouts_window",   type = "number", default = 10, min = 4, max = 60, section = "link" },
  { key = "link_repeat",       type = "number", default = 0, min = 0, max = 10, section = "link" },
  { key = "link_haptic",       type = "bool", default = true,  section = "link" },
  { key = "adjustment_events", type = "bool", default = false, section = "adjustment" },
  { key = "fuel_alerts",       type = "bool", default = true,  section = "fuel" },
  -- No range: the callout step is a choice out of FUEL_CALLOUT_VALUES below, not a free number.
  { key = "fuel_callout_percent", type = "number", default = 10, section = "fuel" },
  -- The fuel category's pair of the two above. They keep the keys and the defaults they were
  -- given when this alert was the only one in the tree that had either property, so an
  -- existing preferences.ini reads exactly as it did; what changed is that the same two
  -- properties now exist for the other categories rather than for this one alone. The range
  -- starts at 0 like the others, which is the value that was not expressible before.
  { key = "fuel_repeat_below_zero", type = "number", default = 1, min = 0, max = 10, section = "fuel" },
  { key = "fuel_haptic_below_zero", type = "bool", default = false, section = "fuel" },
  -- A second, finer callout step below a level (lib/audio.lua, fuelThresholdList). Choices out of
  -- FUEL_FINER_BELOW_VALUES and FUEL_FINER_STEP_VALUES below; 0 is Off, so a preferences.ini
  -- without the keys speaks the steps it always did.
  { key = "fuel_finer_below", type = "number", default = 0, section = "fuel" },
  { key = "fuel_finer_step", type = "number", default = 5, section = "fuel" },
  -- What is said once when a model connects has a page of its own, whatever quantity each
  -- announcement reads. The keys are the ones these settings always had, so an existing
  -- preferences file reads exactly as it did; only the page that draws and saves them changed.
  { key = "model_announcement",type = "bool", default = false, section = "connect" },
  { key = "pack_not_full",     type = "bool", default = false, section = "connect" },
  -- Millivolts per cell, so the number reads the same whatever the pack is: 100 is a tenth of
  -- a volt below the configured full cell voltage. 0, the default, is the firmware's own rule;
  -- the range starts there so that the load clamp below cannot turn the default into another value.
  { key = "pack_not_full_margin", type = "number", default = 0, min = 0, max = 500, section = "connect" },
  { key = "battery_profile",   type = "bool", default = true,  section = "connect" },
  { key = "initial_fuel",      type = "bool", default = true,  section = "connect" },
  -- The start of a rescue and its end, each spoken under a switch of its own. Both default to off,
  -- so a radio that never opens this page announces nothing new.
  { key = "rescue_active",     type = "bool", default = false, section = "rescue" },
  { key = "rescue_off",        type = "bool", default = false, section = "rescue" },
  -- Raise Volume, one switch per alarm: in the Master volume mode of Settings > Audio > Volume the
  -- master volume goes to the Alert Level right before that alarm's critical announcement plays
  -- (its upper level, or its only one) and back a few seconds after the last (lib/audio.lua,
  -- tryPlayAlertFile). On for every alarm, so a pilot who sets up the master volume hears every
  -- alarm raised without visiting four pages; off for telemetry dropouts, a rate of missed frames
  -- rather than a danger in itself. The BEC and the RX voltage alert share one switch: only one of
  -- the two is on at a time (Setup > Power > Alerts). No effect in the other modes, and none on the
  -- haptic. Each row is drawn only while its alarm is switched on, as the governor's state rows are:
  -- a volume rule for an alarm that is off says nothing, and a page whose alarms are off costs
  -- what it did. The BEC/RX row has no switch on its page to follow and is always drawn.
  { key = "voltage_raise",         type = "bool", default = true,  section = "voltage" },
  { key = "main_power_raise",      type = "bool", default = true,  section = "voltage" },
  { key = "bec_rx_raise",          type = "bool", default = true,  section = "voltage" },
  { key = "esc_temperature_raise", type = "bool", default = true,  section = "esc" },
  { key = "mcu_temperature_raise", type = "bool", default = true,  section = "esc" },
  { key = "esc_load_raise",        type = "bool", default = true,  section = "esc" },
  { key = "lq_raise",              type = "bool", default = true,  section = "link" },
  { key = "telemetry_lost_raise",  type = "bool", default = true,  section = "link" },
  { key = "tpwr_raise",            type = "bool", default = true,  section = "link" },
  { key = "rssi_raise",            type = "bool", default = true,  section = "link" },
  { key = "trss_raise",            type = "bool", default = true,  section = "link" },
  { key = "rsnr_raise",            type = "bool", default = true,  section = "link" },
  { key = "tsnr_raise",            type = "bool", default = true,  section = "link" },
  { key = "dropouts_raise",        type = "bool", default = false, section = "link" },
  { key = "fuel_empty_raise",      type = "bool", default = true,  section = "fuel" },
}

-- One enable per governor state, under the `governor_state` master switch. They default to on,
-- so a preferences.ini written before they existed announces every state, as it did.
for i = 1, #GOVERNOR_STATES do
  CONFIG_SCHEMA[#CONFIG_SCHEMA + 1] = {
    key = GOVERNOR_STATES[i].key, type = "bool", default = true, section = "governor"
  }
end

-- The schema by key, so that a row being drawn can reach its own range without walking the
-- list once per row; and the schema split by the page that owns each entry, so that a page
-- loading its settings walks only its own entries rather than every setting another page adds.
-- Both are built in one walk when this file is loaded, which happens in the pass that opens a
-- page.
local SCHEMA_BY_KEY = {}
local SECTION_FIELDS = {}
for i = 1, #CONFIG_SCHEMA do
  local field = CONFIG_SCHEMA[i]
  SCHEMA_BY_KEY[field.key] = field
  local fields = SECTION_FIELDS[field.section]
  if not fields then
    fields = {}
    SECTION_FIELDS[field.section] = fields
  end
  fields[#fields + 1] = field
end

-- ─── Sections ────────────────────────────────────────────────────────────────
-- One entry per page. An item with `requires` is drawn only while that switch is on: the
-- per-state rows qualify the governor master switch, and ten greyed-out rows under a switch
-- that is off would say nothing the switch does not. An item with `enabledBy` is always
-- drawn and is editable only while that switch is on, which is what a single threshold
-- under its own enable wants: the value stays readable.

local SECTIONS = {
  arming = {
    titleKey = "section_arming",
    titleFallback = "Arming Flags",
    items = {
      { key = "arming_flags", labelKey = "arming_flags", labelFallback = "Arming Flags" },
    },
  },
  governor = {
    titleKey = "section_governor",
    titleFallback = "Governor State",
    items = {
      { key = "governor_state", labelKey = "governor_state", labelFallback = "Governor State" },
      { kind = "subheader", labelKey = "section_governor_states", labelFallback = "Announced states", requires = "governor_state" },
    },
  },
  voltage = {
    titleKey = "section_voltage",
    titleFallback = "Voltage",
    items = {
      { key = "voltage_alert", labelKey = "voltage_alert", labelFallback = "Voltage" },
      { kind = "bool", key = "voltage_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "voltage_alert" },
      { kind = "number", key = "voltage_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)",
        suffix = " s", enabledBy = "voltage_alert" },
      { kind = "number", key = "voltage_reset", labelKey = "voltage_reset", labelFallback = "Reset (mV/cell)",
        suffix = " mV", step = 50, enabledBy = "voltage_alert" },
      -- Its own subheader, because it is not a threshold on the pack voltage above but a
      -- different event that happens to be read off the same sensor.
      { kind = "subheader", labelKey = "section_main_power", labelFallback = "Main Power" },
      { kind = "bool", key = "main_power_lost", labelKey = "main_power_lost", labelFallback = "Main Power Lost" },
      { kind = "bool", key = "main_power_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "main_power_lost" },
      { kind = "subheader", labelKey = "section_alert_behaviour", labelFallback = "Alert Behaviour" },
      -- No enabledBy: besides the alert above it governs the main pack coming back and the pack
      -- check on connect, which do not depend on the Voltage switch.
      { kind = "choice", key = "voltage_announce", labelKey = "voltage_announce", labelFallback = "Announce as" },
      { kind = "choice", key = "voltage_repeat", labelKey = "alert_repeat", labelFallback = "Repeat" },
      { kind = "bool", key = "voltage_haptic", labelKey = "alert_haptic", labelFallback = "Haptic" },
      -- Beside the Repeat and Haptic rows that already govern the BEC/RX alert, which has no row of
      -- its own on this page: it is switched on under Setup > Power > Alerts.
      { kind = "bool", key = "bec_rx_raise", labelKey = "bec_rx_raise", labelFallback = "Raise Volume BEC/RX" },
    },
  },
  profiles = {
    titleKey = "section_profiles",
    titleFallback = "PID/Rate Profile",
    items = {
      { key = "pid_profile",  labelKey = "pid_profile",  labelFallback = "PID Profile" },
      { key = "rate_profile", labelKey = "rate_profile", labelFallback = "Rate Profile" },
    },
  },
  esc = {
    titleKey = "section_esc",
    titleFallback = "ESC Temperature",
    items = {
      { kind = "bool", key = "esc_temperature", labelKey = "esc_temperature", labelFallback = "ESC Temperature" },
      { kind = "bool", key = "esc_temperature_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "esc_temperature" },
      { kind = "number", key = "esc_threshold", labelKey = "esc_threshold", labelFallback = "Warning", suffix = "°C",
        temperature = true, enabledBy = "esc_temperature" },
      { kind = "number", key = "esc_critical", labelKey = "esc_critical", labelFallback = "Critical", suffix = "°C",
        temperature = true, enabledBy = "esc_temperature" },
      { kind = "subheader", labelKey = "section_mcu", labelFallback = "MCU Temperature" },
      { kind = "bool", key = "mcu_temperature", labelKey = "mcu_temperature", labelFallback = "MCU Temperature" },
      { kind = "bool", key = "mcu_temperature_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "mcu_temperature" },
      -- The labels of the ESC levels, on purpose: the rows say the same thing, and the
      -- subheader above them is what tells the two pairs apart. modelScopeLabel keys on
      -- the row's own key, so these carry no [Model] marker.
      { kind = "number", key = "mcu_threshold", labelKey = "esc_threshold", labelFallback = "Warning", suffix = "°C",
        temperature = true, enabledBy = "mcu_temperature" },
      { kind = "number", key = "mcu_critical", labelKey = "esc_critical", labelFallback = "Critical", suffix = "°C",
        temperature = true, enabledBy = "mcu_temperature" },
      -- The level labels of the link quality alert and the hold label of the voltage alert: the
      -- rows mean the same thing, and the subheader says which alert they belong to.
      { kind = "subheader", labelKey = "section_esc_load", labelFallback = "ESC Load" },
      { kind = "bool", key = "esc_load", labelKey = "esc_load", labelFallback = "ESC Load" },
      { kind = "bool", key = "esc_load_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "esc_load" },
      { kind = "number", key = "esc_load_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        step = 5, enabledBy = "esc_load" },
      { kind = "number", key = "esc_load_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        step = 5, enabledBy = "esc_load" },
      { kind = "number", key = "esc_load_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)",
        suffix = " s", enabledBy = "esc_load" },
      { kind = "subheader", labelKey = "section_alert_behaviour", labelFallback = "Alert Behaviour" },
      { kind = "choice", key = "esc_repeat", labelKey = "alert_repeat", labelFallback = "Repeat" },
      { kind = "bool", key = "esc_haptic", labelKey = "alert_haptic", labelFallback = "Haptic" },
    },
  },
  link = {
    titleKey = "section_link",
    titleFallback = "Link Quality",
    items = {
      { kind = "bool", key = "lq_alert", labelKey = "lq_alert", labelFallback = "Link Quality" },
      { kind = "bool", key = "lq_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "lq_alert" },
      { kind = "number", key = "lq_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "lq_alert" },
      { kind = "number", key = "lq_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "lq_alert" },
      { kind = "subheader", labelKey = "section_telemetry", labelFallback = "Telemetry" },
      { kind = "bool", key = "telemetry_lost", labelKey = "telemetry_lost", labelFallback = "Telemetry Lost" },
      { kind = "bool", key = "telemetry_lost_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "telemetry_lost" },
      { kind = "bool", key = "dropouts_alert", labelKey = "dropouts_alert", labelFallback = "Telemetry Dropouts" },
      { kind = "bool", key = "dropouts_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "dropouts_alert" },
      { kind = "number", key = "dropouts_count", labelKey = "dropouts_count", labelFallback = "Dropouts",
        enabledBy = "dropouts_alert" },
      { kind = "number", key = "dropouts_window", labelKey = "dropouts_window", labelFallback = "Window (s)",
        suffix = " s", enabledBy = "dropouts_alert" },
      -- The level rows take the labels of the link quality rows above and the hold row the label of
      -- the voltage page's: they say the same thing, and the subheader tells the alerts apart.
      { kind = "subheader", labelKey = "section_tx_power", labelFallback = "TX Power" },
      { kind = "bool", key = "tpwr_alert", labelKey = "tpwr_alert", labelFallback = "TX Power" },
      { kind = "bool", key = "tpwr_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "tpwr_alert" },
      { kind = "number", key = "tpwr_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "tpwr_alert" },
      { kind = "number", key = "tpwr_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "tpwr_alert" },
      { kind = "number", key = "tpwr_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)", suffix = " s",
        enabledBy = "tpwr_alert" },
      { kind = "bool", key = "tpwr_limit", labelKey = "tpwr_limit", labelFallback = "Own Maximum" },
      { kind = "choice", key = "tpwr_max", labelKey = "tpwr_max", labelFallback = "Maximum (mW)", enabledBy = "tpwr_limit" },
      -- The level labels of the link quality alert and the hold label of the voltage alert: the
      -- rows mean the same thing, and the subheader says which alert they belong to.
      { kind = "subheader", labelKey = "rssi_alert", labelFallback = "RSSI" },
      { kind = "bool", key = "rssi_alert", labelKey = "rssi_alert", labelFallback = "RSSI" },
      { kind = "bool", key = "rssi_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "rssi_alert" },
      { kind = "number", key = "rssi_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "rssi_alert" },
      { kind = "number", key = "rssi_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "rssi_alert" },
      { kind = "number", key = "rssi_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)", suffix = " s",
        enabledBy = "rssi_alert" },
      { kind = "subheader", labelKey = "trss_alert", labelFallback = "Downlink" },
      { kind = "bool", key = "trss_alert", labelKey = "trss_alert", labelFallback = "Downlink" },
      { kind = "bool", key = "trss_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "trss_alert" },
      { kind = "number", key = "trss_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "trss_alert" },
      { kind = "number", key = "trss_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "trss_alert" },
      { kind = "number", key = "trss_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)", suffix = " s",
        enabledBy = "trss_alert" },
      { kind = "subheader", labelKey = "rsnr_alert", labelFallback = "SNR" },
      { kind = "bool", key = "rsnr_alert", labelKey = "rsnr_alert", labelFallback = "SNR" },
      { kind = "bool", key = "rsnr_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "rsnr_alert" },
      { kind = "number", key = "rsnr_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "rsnr_alert" },
      { kind = "number", key = "rsnr_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "rsnr_alert" },
      { kind = "number", key = "rsnr_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)", suffix = " s",
        enabledBy = "rsnr_alert" },
      { kind = "subheader", labelKey = "tsnr_alert", labelFallback = "Downlink SNR" },
      { kind = "bool", key = "tsnr_alert", labelKey = "tsnr_alert", labelFallback = "Downlink SNR" },
      { kind = "bool", key = "tsnr_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "tsnr_alert" },
      { kind = "number", key = "tsnr_warn", labelKey = "lq_warn", labelFallback = "Warning (%)", suffix = "%",
        enabledBy = "tsnr_alert" },
      { kind = "number", key = "tsnr_critical", labelKey = "lq_critical", labelFallback = "Critical (%)", suffix = "%",
        enabledBy = "tsnr_alert" },
      { kind = "number", key = "tsnr_hold", labelKey = "voltage_hold", labelFallback = "Hold (s)", suffix = " s",
        enabledBy = "tsnr_alert" },
      { kind = "subheader", labelKey = "section_alert_behaviour", labelFallback = "Alert Behaviour" },
      { kind = "choice", key = "link_repeat", labelKey = "alert_repeat", labelFallback = "Repeat" },
      { kind = "bool", key = "link_haptic", labelKey = "alert_haptic", labelFallback = "Haptic" },
    },
  },
  adjustment = {
    titleKey = "section_adjustment",
    titleFallback = "Adjustment Announcements",
    items = {
      { key = "adjustment_events", labelKey = "adjustment_events", labelFallback = "Adjustment Announcements" },
    },
  },
  -- Named after the feature that produces the value it reads, as Setup > Power > SmartFuel and
  -- the configurator call it. `section_fuel` keeps its old text because a dashboard theme reads it.
  fuel = {
    titleKey = "section_smartfuel",
    titleFallback = "SmartFuel",
    items = {
      { kind = "bool", key = "fuel_alerts", labelKey = "fuel_alerts", labelFallback = "SmartFuel" },
      { kind = "choice", key = "fuel_callout_percent", labelKey = "fuel_callout_percent", labelFallback = "Callout %" },
      -- The step below the level the row above it names; drawn greyed while that row is Off.
      { kind = "choice", key = "fuel_finer_below", labelKey = "fuel_finer_below", labelFallback = "Finer below" },
      { kind = "choice", key = "fuel_finer_step", labelKey = "fuel_finer_step", labelFallback = "Finer step" },
      -- The same two rows the other categories carry, under the same subheader. The empty
      -- alert is the only one on this page that has a condition to hold, so the pair reads
      -- the same as the "below 0%" wording it replaces and means exactly what it did.
      { kind = "subheader", labelKey = "section_alert_behaviour", labelFallback = "Alert Behaviour" },
      { kind = "choice", key = "fuel_repeat_below_zero", labelKey = "alert_repeat", labelFallback = "Repeat",
        enabledBy = "fuel_alerts" },
      { kind = "bool", key = "fuel_haptic_below_zero", labelKey = "alert_haptic", labelFallback = "Haptic" },
      { kind = "bool", key = "fuel_empty_raise", labelKey = "alert_raise", labelFallback = "Raise Volume",
        requires = "fuel_alerts" },
    },
  },
  -- The rows in the order lib/audio.lua speaks them after a connect. The dashboard's audio pass
  -- starts once the connect tasks have read the battery configuration, so its first pass plays
  -- the model's name and judges the pack, which is not gated on `initialized`; the capacity is,
  -- and follows a pass later; the SmartFuel level comes last, once its reading has settled.
  connect = {
    titleKey = "section_connect",
    titleFallback = "On Connect",
    items = {
      { kind = "bool", key = "model_announcement", labelKey = "model_announcement", labelFallback = "Model Name" },
      { kind = "bool", key = "pack_not_full", labelKey = "pack_not_full", labelFallback = "Pack Not Full" },
      { kind = "number", key = "pack_not_full_margin", labelKey = "pack_not_full_margin", labelFallback = "Margin (mV/cell)",
        suffix = " mV", enabledBy = "pack_not_full" },
      { kind = "bool", key = "battery_profile", labelKey = "battery_profile", labelFallback = "Battery Capacity" },
      { kind = "bool", key = "initial_fuel", labelKey = "initial_fuel", labelFallback = "SmartFuel" },
    },
  },
  -- Two events rather than an alert, so no Repeat and no Haptic: the pilot usually starts a rescue
  -- himself, and a confirmation is all it needs.
  rescue = {
    titleKey = "section_rescue",
    titleFallback = "Rescue",
    items = {
      { kind = "bool", key = "rescue_active", labelKey = "rescue_active", labelFallback = "Rescue Active" },
      { kind = "bool", key = "rescue_off", labelKey = "rescue_off", labelFallback = "Rescue Off" },
    },
  },
}

for i = 1, #GOVERNOR_STATES do
  local state = GOVERNOR_STATES[i]
  local items = SECTIONS.governor.items
  items[#items + 1] = {
    key = state.key, labelKey = state.labelKey, labelFallback = state.labelFallback, requires = "governor_state"
  }
end

-- ─── Row help ────────────────────────────────────────────────────────────────
-- The text behind each row's `?` button, one function per page, so a page resolves its own texts
-- and no others. The keys are written out in t() calls because the packager translates a key only
-- where it is a quoted literal; a key read from the row would reach the radio untranslated. The
-- governor's per-state rows mean the same thing each, so they share one text.

local ROW_HELP = {
  connect = function(t, i18n)
    return {
      model_announcement = t(i18n, "help_model_announcement"),
      battery_profile = t(i18n, "help_battery_profile"),
      pack_not_full = t(i18n, "help_pack_not_full"),
      pack_not_full_margin = t(i18n, "help_pack_not_full_margin"),
      initial_fuel = t(i18n, "help_initial_fuel"),
    }
  end,
  arming = function(t, i18n)
    return {
      arming_flags = t(i18n, "help_arming_flags"),
    }
  end,
  governor = function(t, i18n)
    local stateRow = t(i18n, "help_governor_state_row")
    local texts = {
      governor_state = t(i18n, "help_governor_state"),
    }
    for i = 1, #GOVERNOR_STATES do
      texts[GOVERNOR_STATES[i].key] = stateRow
    end
    return texts
  end,
  voltage = function(t, i18n)
    local event = t(i18n, "help_raise_event")
    return {
      voltage_alert = t(i18n, "help_voltage_alert"),
      voltage_hold = t(i18n, "help_voltage_hold"),
      voltage_reset = t(i18n, "help_voltage_reset"),
      main_power_lost = t(i18n, "help_main_power_lost"),
      voltage_announce = t(i18n, "help_voltage_announce"),
      voltage_repeat = t(i18n, "help_voltage_repeat"),
      voltage_haptic = t(i18n, "help_voltage_haptic"),
      voltage_raise = t(i18n, "help_voltage_raise"),
      main_power_raise = event,
      bec_rx_raise = t(i18n, "help_bec_rx_raise"),
    }
  end,
  profiles = function(t, i18n)
    return {
      pid_profile = t(i18n, "help_pid_profile"),
      rate_profile = t(i18n, "help_rate_profile"),
    }
  end,
  esc = function(t, i18n)
    local critical = t(i18n, "help_raise_critical")
    return {
      esc_temperature = t(i18n, "help_esc_temperature"),
      esc_threshold = t(i18n, "help_esc_threshold"),
      esc_critical = t(i18n, "help_esc_critical"),
      mcu_temperature = t(i18n, "help_mcu_temperature"),
      mcu_threshold = t(i18n, "help_mcu_threshold"),
      esc_load = t(i18n, "help_esc_load"),
      esc_load_warn = t(i18n, "help_esc_load_warn"),
      esc_load_critical = t(i18n, "help_esc_load_critical"),
      esc_load_hold = t(i18n, "help_esc_load_hold"),
      mcu_critical = t(i18n, "help_mcu_critical"),
      esc_repeat = t(i18n, "help_esc_repeat"),
      esc_haptic = t(i18n, "help_esc_haptic"),
      esc_temperature_raise = critical,
      mcu_temperature_raise = critical,
      esc_load_raise = critical,
    }
  end,
  adjustment = function(t, i18n)
    return {
      adjustment_events = t(i18n, "help_adjustment_events"),
    }
  end,
  fuel = function(t, i18n)
    return {
      fuel_alerts = t(i18n, "help_fuel_alerts"),
      fuel_callout_percent = t(i18n, "help_fuel_callout_percent"),
      fuel_finer_below = t(i18n, "help_fuel_finer_below"),
      fuel_finer_step = t(i18n, "help_fuel_finer_step"),
      fuel_repeat_below_zero = t(i18n, "help_fuel_repeat_below_zero"),
      fuel_haptic_below_zero = t(i18n, "help_fuel_haptic_below_zero"),
      fuel_empty_raise = t(i18n, "help_fuel_empty_raise"),
    }
  end,
  -- The RSSI and Downlink rows share their three level texts, and so do the two SNR alerts:
  -- each shared text is looked up once.
  link = function(t, i18n)
    local headroomWarn = t(i18n, "help_headroom_warn")
    local headroomCritical = t(i18n, "help_headroom_critical")
    local headroomHold = t(i18n, "help_headroom_hold")
    local snrWarn = t(i18n, "help_snr_warn")
    local snrCritical = t(i18n, "help_snr_critical")
    local snrHold = t(i18n, "help_snr_hold")
    local critical = t(i18n, "help_raise_critical")
    return {
      lq_alert = t(i18n, "help_lq_alert"),
      lq_warn = t(i18n, "help_lq_warn"),
      lq_critical = t(i18n, "help_lq_critical"),
      telemetry_lost = t(i18n, "help_telemetry_lost"),
      tpwr_alert = t(i18n, "help_tpwr_alert"),
      tpwr_warn = t(i18n, "help_tpwr_warn"),
      tpwr_critical = t(i18n, "help_tpwr_critical"),
      tpwr_hold = t(i18n, "help_tpwr_hold"),
      tpwr_limit = t(i18n, "help_tpwr_limit"),
      tpwr_max = t(i18n, "help_tpwr_max"),
      rssi_alert = t(i18n, "help_rssi_alert"),
      rssi_warn = headroomWarn,
      rssi_critical = headroomCritical,
      rssi_hold = headroomHold,
      trss_alert = t(i18n, "help_trss_alert"),
      trss_warn = headroomWarn,
      trss_critical = headroomCritical,
      trss_hold = headroomHold,
      rsnr_alert = t(i18n, "help_rsnr_alert"),
      rsnr_warn = snrWarn,
      rsnr_critical = snrCritical,
      rsnr_hold = snrHold,
      tsnr_alert = t(i18n, "help_tsnr_alert"),
      tsnr_warn = snrWarn,
      tsnr_critical = snrCritical,
      tsnr_hold = snrHold,
      dropouts_alert = t(i18n, "help_dropouts_alert"),
      dropouts_count = t(i18n, "help_dropouts_count"),
      dropouts_window = t(i18n, "help_dropouts_window"),
      link_repeat = t(i18n, "help_link_repeat"),
      link_haptic = t(i18n, "help_link_haptic"),
      lq_raise = critical,
      telemetry_lost_raise = t(i18n, "help_raise_event"),
      tpwr_raise = critical,
      rssi_raise = critical,
      trss_raise = critical,
      rsnr_raise = critical,
      tsnr_raise = critical,
      dropouts_raise = t(i18n, "help_dropouts_raise"),
    }
  end,
  rescue = function(t, i18n)
    return {
      rescue_active = t(i18n, "help_rescue_active"),
      rescue_off = t(i18n, "help_rescue_off"),
    }
  end,
}

local FUEL_CALLOUT_VALUES = { [0] = true, [5] = true, [10] = true, [20] = true, [25] = true, [50] = true }
-- The same two lists lib/audio.lua accepts (FUEL_FINER_BELOW, FUEL_FINER_STEP); 0 is Off.
-- The levels are shown as numbers with the unit, as the TX power maximum is, so their options
-- are built once here; only Off is a word, and its label is set when a page is built.
local FUEL_FINER_BELOW_LIST = { 0, 10, 15, 20, 25, 30, 40, 50 }
local FUEL_FINER_BELOW_VALUES = {}
local FUEL_FINER_BELOW_OPTIONS = {}
for i = 1, #FUEL_FINER_BELOW_LIST do
  local level = FUEL_FINER_BELOW_LIST[i]
  FUEL_FINER_BELOW_VALUES[level] = true
  FUEL_FINER_BELOW_OPTIONS[i] = { value = level, label = tostring(level) .. "%" }
end
local FUEL_FINER_STEP_VALUES = { [1] = true, [2] = true, [5] = true }

-- The own maximum of the TX power alert, in mW: the power steps ExpressLRS offers above its lowest
-- (TXModuleParameters.cpp, strPowerLevels), which is also the list the Urban theme's own power
-- limit offers.
local TX_POWER_MAX_LIST = { 25, 50, 100, 250, 500, 1000, 2000 }
local TX_POWER_MAX_VALUES = {}
for i = 1, #TX_POWER_MAX_LIST do TX_POWER_MAX_VALUES[TX_POWER_MAX_LIST[i]] = true end

-- The per-model store hangs off the session and exists only once the flight controller's
-- id has been read, so every caller here has to cope with it being absent. The session is
-- returned rather than a boolean, because every caller that asks then needs it.
local function modelStore()
  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  if not session or not session.mcu_id or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session
end

local function modelAudioEvents(create)
  local session = modelStore()
  if not session then return nil end
  if type(session.modelPreferences.audio_events) ~= "table" then
    if not create then return nil end
    session.modelPreferences.audio_events = {}
  end
  return session.modelPreferences.audio_events
end

-- ctx.savePreferences() writes the global file only, so a page that puts a value in the
-- per-model store has to persist that store itself -- and has to be able to say so when
-- the write fails, or it reports a save the store never got.
local function saveModelStore()
  local session = modelStore()
  if not session then return true end
  -- A module that will not load answers as saveByMcuId does when it has no store: "unavailable".
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/model_preferences.lua", "t")
  if type(chunk) ~= "function" then return false, "unavailable" end
  local loaded, MP = pcall(chunk)
  if not (loaded and type(MP) == "table" and type(MP.saveByMcuId) == "function") then
    return false, "unavailable"
  end
  return MP.saveByMcuId(session.mcu_id, session.modelPreferences)
end

local function prefBool(value, default)
  if value == nil then return default end
  return value == true or value == "true" or value == 1 or value == "1"
end

-- The four temperature levels (ESC and MCU, warning and critical) are stored in Celsius, the
-- unit the flight controller reports and lib/audio.lua compares in. On a radio set to
-- Fahrenheit under Settings > Localization they are shown in Fahrenheit, like every other
-- temperature the suite shows. Only the text changes: the control still steps one degree
-- Celsius and stores what it shows, so nothing is rounded twice.
local function usesFahrenheit(prefs)
  local localizations = prefs and prefs.localizations
  return tonumber(localizations and localizations.temperature_unit) == 1
end

local function fahrenheitText(celsius)
  return tostring(math.floor(celsius * 9 / 5 + 32 + 0.5)) .. "°F"
end

-- ─── Page factory ────────────────────────────────────────────────────────────

function M.new(sectionKey)
  local section = SECTIONS[sectionKey]
  assert(section ~= nil, "unknown audio events category: " .. tostring(sectionKey))

  local page = {}
  local Controls = nil
  local Common = nil
  local t = nil

  local ui = {
    loaded = false,
    dirty = false,
    config = {},
    runtime = {
      -- The number rows share one set of closures keyed on the row's own key, so a page
      -- that gains a threshold gains no code here.
      numberEnabled = nil,
      numberGetters = nil,
      numberSetters = nil,
      repeatGetters = nil,
      repeatSetters = nil,
      fuelCalloutGet = nil,
      fuelCalloutSet = nil,
      fuelFinerBelowGet = nil,
      fuelFinerBelowSet = nil,
      fuelFinerStepGet = nil,
      fuelFinerStepSet = nil,
      fuelHapticGet = nil,
      fuelHapticSet = nil,
      announceGet = nil,
      announceSet = nil
    }
  }
  ui.runtimeBase = nil

  -- What copyFromPrefs put into ui.config. A save reads it to tell a field the pilot changed
  -- from one that merely carries the value it was loaded with.
  local loadedConfig = {}

  local function ownsField(field)
    return field.section == sectionKey
  end

  local ownFields = SECTION_FIELDS[sectionKey] or {}

  -- Only this page's own keys: every read and write of ui.config here is of a key the page draws
  -- or saves, so another page's defaults would be built for nothing in the pass that opens it.
  for i = 1, #ownFields do
    local field = ownFields[i]
    ui.config[field.key] = field.default
  end

  local function ensureDeps()
    if not Common then
      Common = loadModule("app/pages/settings/common.lua")
    end
    if not Controls then
      Controls = loadModule("ui/controls.lua")
    end
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createFormRuntime(ui)
      if type(ui.runtime) ~= "table" then ui.runtime = {} end
      setmetatable(ui.runtime, {__index = ui.runtimeBase})
    end
    if not t then
      -- Every category page reads the same translation block: the labels were there before
      -- the page was split, and a split is not a reason to spell them twice.
      t = Common.pageT("settings_audio_events")
    end
  end

  -- The closures behind the number rows. appendNumberField keeps whatever it is handed for
  -- the life of the control, so a fresh closure per build would leave the previous one
  -- pointing at a page state that is about to be replaced. They are cached on ui.runtime,
  -- which onClose drops, and keyed on the row's own key rather than named per row.
  local function numberCache(name)
    local cache = rawget(ui.runtime, name)
    if type(cache) ~= "table" then
      cache = {}
      ui.runtime[name] = cache
    end
    return cache
  end

  -- Nil for a row that has no `enabledBy`: appendNumberField then leaves the control enabled.
  -- The three number-row helpers take their cache from the caller, which looks each one up once
  -- per build rather than once per row.
  local function getNumberEnabled(cache, enabledBy)
    if type(enabledBy) ~= "string" then return nil end
    if cache[enabledBy] then return cache[enabledBy] end
    cache[enabledBy] = function()
      return ui.config[enabledBy] == true
    end
    return cache[enabledBy]
  end

  local function getNumberGetter(cache, key, minVal, maxVal)
    if cache[key] then return cache[key] end
    cache[key] = function()
      local current = tonumber(ui.config[key]) or minVal
      if current < minVal then current = minVal end
      if current > maxVal then current = maxVal end
      return current
    end
    return cache[key]
  end

  local function getNumberSetter(cache, key, enabledBy, minVal, maxVal)
    if cache[key] then return cache[key] end
    cache[key] = function(value)
      if type(enabledBy) == "string" and ui.config[enabledBy] ~= true then return end
      local nextValue = tonumber(value) or minVal
      if nextValue < minVal then nextValue = minVal end
      if nextValue > maxVal then nextValue = maxVal end
      if ui.config[key] ~= nextValue then
        ui.config[key] = nextValue
        -- markValueChanged rather than markDirty: a numberEdit is edited in place, and the
        -- rebuild markDirty asks for would destroy the editor between two clicks.
        ui.runtime.markValueChanged()
      end
    end
    return cache[key]
  end

  local function getFuelCalloutOptions(i18n)
    return {
      { value = 0, label = t(i18n, "fuel_callout_only_10", "Only at 10%") },
      { value = 5, label = t(i18n, "fuel_callout_5", "Every 5%") },
      { value = 10, label = t(i18n, "fuel_callout_10", "Every 10%") },
      { value = 20, label = t(i18n, "fuel_callout_20", "Every 20%") },
      { value = 25, label = t(i18n, "fuel_callout_25", "Every 25%") },
      { value = 50, label = t(i18n, "fuel_callout_50", "Every 50%") },
    }
  end

  local function getFuelCalloutGetter()
    if ui.runtime.fuelCalloutGet then return ui.runtime.fuelCalloutGet end
    ui.runtime.fuelCalloutGet = function()
      local value = tonumber(ui.config.fuel_callout_percent) or 10
      if not FUEL_CALLOUT_VALUES[value] then return 10 end
      return value
    end
    return ui.runtime.fuelCalloutGet
  end

  local function getFuelCalloutSetter()
    if ui.runtime.fuelCalloutSet then return ui.runtime.fuelCalloutSet end
    ui.runtime.fuelCalloutSet = function(value)
      if ui.config.fuel_alerts ~= true then return end
      local nextValue = tonumber(value) or 10
      if not FUEL_CALLOUT_VALUES[nextValue] then nextValue = 10 end
      if ui.config.fuel_callout_percent ~= nextValue then
        ui.config.fuel_callout_percent = nextValue
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelCalloutSet
  end

  -- *Finer below*: Off, or the level below which the callout speaks every *Finer step*.
  local function getFuelFinerBelowOptions(i18n)
    FUEL_FINER_BELOW_OPTIONS[1].label = t(i18n, "fuel_finer_off", "Off")
    return FUEL_FINER_BELOW_OPTIONS
  end

  local function getFuelFinerBelowGetter()
    if ui.runtime.fuelFinerBelowGet then return ui.runtime.fuelFinerBelowGet end
    ui.runtime.fuelFinerBelowGet = function()
      local value = tonumber(ui.config.fuel_finer_below) or 0
      if not FUEL_FINER_BELOW_VALUES[value] then return 0 end
      return value
    end
    return ui.runtime.fuelFinerBelowGet
  end

  local function getFuelFinerBelowSetter()
    if ui.runtime.fuelFinerBelowSet then return ui.runtime.fuelFinerBelowSet end
    ui.runtime.fuelFinerBelowSet = function(value)
      if ui.config.fuel_alerts ~= true then return end
      local nextValue = tonumber(value) or 0
      if not FUEL_FINER_BELOW_VALUES[nextValue] then nextValue = 0 end
      if ui.config.fuel_finer_below ~= nextValue then
        ui.config.fuel_finer_below = nextValue
        -- A rebuild, so the *Finer step* row below is drawn greyed or live to match.
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelFinerBelowSet
  end

  local function getFuelFinerStepOptions(i18n)
    return {
      { value = 1, label = t(i18n, "fuel_callout_1", "Every 1%") },
      { value = 2, label = t(i18n, "fuel_callout_2", "Every 2%") },
      { value = 5, label = t(i18n, "fuel_callout_5", "Every 5%") },
    }
  end

  local function getFuelFinerStepGetter()
    if ui.runtime.fuelFinerStepGet then return ui.runtime.fuelFinerStepGet end
    ui.runtime.fuelFinerStepGet = function()
      local value = tonumber(ui.config.fuel_finer_step) or 5
      if not FUEL_FINER_STEP_VALUES[value] then return 5 end
      return value
    end
    return ui.runtime.fuelFinerStepGet
  end

  -- Editable only while *Finer below* names a level: with it Off the step is never used.
  local function fuelFinerActive()
    return (tonumber(ui.config.fuel_finer_below) or 0) ~= 0
  end

  local function getFuelFinerStepSetter()
    if ui.runtime.fuelFinerStepSet then return ui.runtime.fuelFinerStepSet end
    ui.runtime.fuelFinerStepSet = function(value)
      if ui.config.fuel_alerts ~= true or not fuelFinerActive() then return end
      local nextValue = tonumber(value) or 5
      if not FUEL_FINER_STEP_VALUES[nextValue] then nextValue = 5 end
      if ui.config.fuel_finer_step ~= nextValue then
        ui.config.fuel_finer_step = nextValue
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelFinerStepSet
  end

  -- The repeat rows all offer the same list, because the number means the same thing on every
  -- page: how many times an alert speaks while one episode of its condition lasts. 0 is the
  -- behaviour every alert had before the setting existed and is spelled out rather than shown
  -- as a zero, which is the one value a pilot could not read off a plain number.
  local function getRepeatOptions(i18n)
    local options = {
      { value = 0, label = t(i18n, "alert_repeat_until_cleared", "Until cleared") },
      { value = 1, label = t(i18n, "alert_repeat_once", "Once") }
    }
    local times = t(i18n, "alert_repeat_times", "x")
    for n = 2, 10 do
      options[#options + 1] = { value = n, label = tostring(n) .. " " .. times }
    end
    return options
  end

  local function getRepeatGetter(key)
    local cache = numberCache("repeatGetters")
    if cache[key] then return cache[key] end
    cache[key] = function()
      local value = tonumber(ui.config[key]) or 0
      if value < 0 then value = 0 end
      if value > 10 then value = 10 end
      return math.floor(value)
    end
    return cache[key]
  end

  local function getRepeatSetter(key, enabledBy)
    local cache = numberCache("repeatSetters")
    if cache[key] then return cache[key] end
    cache[key] = function(value)
      if type(enabledBy) == "string" and ui.config[enabledBy] ~= true then return end
      local nextValue = tonumber(value) or 0
      if nextValue < 0 then nextValue = 0 end
      if nextValue > 10 then nextValue = 10 end
      if ui.config[key] ~= nextValue then
        ui.config[key] = nextValue
        ui.runtime.markDirty()
      end
    end
    return cache[key]
  end

  -- The TX power alert's own maximum: a power step out of TX_POWER_MAX_LIST, shown in mW as the
  -- row's label says. A stored value that is not one of them reads as the default.
  local function getTxPowerMaxOptions()
    local options = {}
    for i = 1, #TX_POWER_MAX_LIST do
      local mw = TX_POWER_MAX_LIST[i]
      options[i] = { value = mw, label = tostring(mw) }
    end
    return options
  end

  local function getTxPowerMaxGetter()
    if ui.runtime.txPowerMaxGet then return ui.runtime.txPowerMaxGet end
    ui.runtime.txPowerMaxGet = function()
      local value = tonumber(ui.config.tpwr_max) or 100
      if not TX_POWER_MAX_VALUES[value] then return 100 end
      return value
    end
    return ui.runtime.txPowerMaxGet
  end

  local function getTxPowerMaxSetter()
    if ui.runtime.txPowerMaxSet then return ui.runtime.txPowerMaxSet end
    ui.runtime.txPowerMaxSet = function(value)
      if ui.config.tpwr_limit ~= true then return end
      local nextValue = tonumber(value) or 100
      if not TX_POWER_MAX_VALUES[nextValue] then nextValue = 100 end
      if ui.config.tpwr_max ~= nextValue then
        ui.config.tpwr_max = nextValue
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.txPowerMaxSet
  end

  -- How a flight-pack voltage is spoken. Two values, so its own pair rather than the repeat
  -- row's, which would let a hand-edited value outside them through.
  local function getAnnounceOptions(i18n)
    return {
      { value = 0, label = t(i18n, "voltage_announce_pack", "Pack") },
      { value = 1, label = t(i18n, "voltage_announce_cell", "Cell") },
    }
  end

  local function getAnnounceGetter()
    if ui.runtime.announceGet then return ui.runtime.announceGet end
    ui.runtime.announceGet = function()
      if tonumber(ui.config.voltage_announce) == 1 then return 1 end
      return 0
    end
    return ui.runtime.announceGet
  end

  local function getAnnounceSetter()
    if ui.runtime.announceSet then return ui.runtime.announceSet end
    ui.runtime.announceSet = function(value)
      local nextValue = (tonumber(value) == 1) and 1 or 0
      if ui.config.voltage_announce ~= nextValue then
        ui.config.voltage_announce = nextValue
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.announceSet
  end

  local function getFuelHapticGetter()
    if ui.runtime.fuelHapticGet then return ui.runtime.fuelHapticGet end
    ui.runtime.fuelHapticGet = function(nextVal)
      if nextVal ~= nil then return end
      return ui.config.fuel_alerts == true and ui.config.fuel_haptic_below_zero == true
    end
    return ui.runtime.fuelHapticGet
  end

  local function getFuelHapticSetter()
    if ui.runtime.fuelHapticSet then return ui.runtime.fuelHapticSet end
    ui.runtime.fuelHapticSet = function(nextVal)
      if ui.config.fuel_alerts ~= true then return end
      local nextBool = (nextVal == true)
      if ui.config.fuel_haptic_below_zero ~= nextBool then
        ui.config.fuel_haptic_below_zero = nextBool
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelHapticSet
  end

  -- Loads this page's settings from preferences using the schema
  local function copyFromPrefs(prefs)
    local audio_events = (prefs and prefs.audio_events) or {}
    local modelEvents = modelAudioEvents(false)
    -- One walk over the page's own fields, which runs in the pass that builds the page.
    for i = 1, #ownFields do
      local field = ownFields[i]
      local key = field.key
      local raw = audio_events[key]
      if field.scope == "model" and modelEvents and modelEvents[key] ~= nil then
        raw = modelEvents[key]
      end
      local value
      if field.type == "number" then
        value = tonumber(raw) or field.default
        -- A stored value outside the schema's range is brought back into it, so that the number
        -- on screen is one the control could have produced. The bounds are the schema's, which
        -- is the same pair the control below is built with; a choice out of a list falls back
        -- to its default.
        if field.min and value < field.min then value = field.min end
        if field.max and value > field.max then value = field.max end
        if key == "fuel_callout_percent" then
          if not FUEL_CALLOUT_VALUES[value] then value = 10 end
        elseif key == "fuel_finer_below" then
          if not FUEL_FINER_BELOW_VALUES[value] then value = 0 end
        elseif key == "fuel_finer_step" then
          if not FUEL_FINER_STEP_VALUES[value] then value = 5 end
        elseif key == "tpwr_max" then
          if not TX_POWER_MAX_VALUES[value] then value = 100 end
        end
      else
        value = prefBool(raw, field.default)
      end
      ui.config[key] = value
      -- After the corrections, so that correcting an out-of-range stored value does not read as
      -- an edit the pilot made.
      loadedConfig[key] = value
    end
  end

  local function ensureLoaded(prefs)
    if ui.loaded then return end
    copyFromPrefs(prefs)
    ui.loaded = true
  end

  -- The ESC's two levels are edited in the model's own store while a flight controller is
  -- connected and in the radio's file otherwise, and nothing on the page says which: a number
  -- entered with a model connected reads as the radio-wide default it no longer is. So the label
  -- carries a marker exactly while the model's store is the one being written.
  --
  -- The keys are spelled out here rather than taken from the schema entry, because the packager
  -- resolves a translation whose key is a literal and a computed one would reach the radio raw.
  local function modelScopeLabel(i18n, key, plain)
    if key == "esc_threshold" then
      if modelStore() then return t(i18n, "esc_threshold_model", "Warning [Model]") end
    elseif key == "esc_critical" then
      if modelStore() then return t(i18n, "esc_critical_model", "Critical [Model]") end
    end
    return plain
  end

  -- A row's `?` opens the same sheet as the header's, through the host's openHelp, with the row's
  -- label as its title. Cached on ui.runtime like the other closures, so onClose drops it.
  local function getInlineHelpHandler()
    if ui.runtime.inlineHelpHandler then return ui.runtime.inlineHelpHandler end
    ui.runtime.inlineHelpHandler = function(helpText, helpTitle)
      local openHelp = ui.runtime.openHelp
      if type(openHelp) == "function" and type(helpText) == "string" and helpText ~= "" then
        openHelp(helpText, helpTitle)
      end
    end
    return ui.runtime.inlineHelpHandler
  end

  -- The options table every row control takes for its `?` button. Nil when the row has no text,
  -- which leaves the control exactly as it is drawn without one. `onHelp` is the handler above,
  -- fetched once per build by the caller.
  local function helpOpts(texts, key, title, onHelp)
    local text = texts[key]
    if type(text) ~= "string" or text == "" then return nil end
    return { helpText = text, helpTitle = title, onHelp = onHelp }
  end

  -- ─── Module API ────────────────────────────────────────────────────────────

  function page.getHeaderActions()
    ensureDeps()
    return { save = true, help = true }
  end

  function page.onReload(ctx)
    ensureDeps()
    copyFromPrefs(ctx.preferences)
    ui.dirty = false
    return true
  end

  function page.onSave(ctx)
    ensureDeps()
    if not ctx.preferences.audio_events then ctx.preferences.audio_events = {} end

    -- Saves this page's settings using the schema. A `scope = "model"` field goes into the
    -- per-model store when there is one to hold it; with no flight controller connected it stays
    -- in the global file, which is also what every model without a store of its own reads.
    --
    -- It goes there only once the model owns that value: either the model already carries one,
    -- or the pilot just changed it here. A model that was never given a limit of its own must
    -- not be pinned to whichever one is current by a save of the radio-wide settings beside it,
    -- because from then on it would no longer follow a change to the global default.
    local modelEvents = modelAudioEvents(false)
    local modelDirty = false
    local modelScoped = false
    -- What this save changes in the session's model table, so that a failed write of the model's
    -- file can put it back. The next save decides whether to write that file by comparing the page
    -- against this table, so a value left in it by a write that failed reads as saved: that save
    -- writes nothing and answers success, and the value is gone at the next start.
    local modelChanged, modelPrevious = {}, {}
    local modelEventsCreated = false
    for _, field in ipairs(CONFIG_SCHEMA) do
      if ownsField(field) then
        local toModel = false
        if field.scope == "model" then
          modelScoped = true
          if modelEvents and modelEvents[field.key] ~= nil then
            toModel = true
          elseif loadedConfig[field.key] ~= nil and ui.config[field.key] ~= loadedConfig[field.key] then
            if not modelEvents then
              modelEvents = modelAudioEvents(true)
              modelEventsCreated = modelEvents ~= nil
            end
            toModel = modelEvents ~= nil
          end
        end
        if toModel then
          if modelEvents[field.key] ~= ui.config[field.key] then
            modelDirty = true
            modelChanged[#modelChanged + 1] = field.key
            modelPrevious[field.key] = modelEvents[field.key]
          end
          modelEvents[field.key] = ui.config[field.key]
        else
          ctx.preferences.audio_events[field.key] = ui.config[field.key]
        end
      end
    end

    local modelOk, modelErr = true, nil
    if modelDirty then
      modelOk, modelErr = saveModelStore()
      if not modelOk then
        -- The session's table goes back to what it held before this save: a key this save added
        -- is removed again, and so is a table this save created.
        for i = 1, #modelChanged do
          modelEvents[modelChanged[i]] = modelPrevious[modelChanged[i]]
        end
        local session = modelEventsCreated and modelStore() or nil
        if session and session.modelPreferences.audio_events == modelEvents then
          session.modelPreferences.audio_events = nil
        end
      end
    end

    -- Diagnostic logging for save flow
    local okLog, Log = pcall(loadModule, "lib/log.lua")
    if okLog and type(Log) == "table" and type(Log.emit) == "function" then
      local parts = {}
      for _, field in ipairs(CONFIG_SCHEMA) do
        if ownsField(field) then
          parts[#parts + 1] = tostring(field.key) .. "=" .. tostring(ui.config[field.key])
        end
      end
      pcall(Log.emit, "rfsuite", "onSave[" .. sectionKey .. "]: audio_events " .. table.concat(parts, ","), "debug")
      if modelScoped then
        -- The line above shows the value the page holds, not where it went: a `scope = "model"`
        -- field is not written to the global store while the model holds it.
        local parts2 = {}
        for _, field in ipairs(CONFIG_SCHEMA) do
          if ownsField(field) and field.scope == "model" then
            local v = modelEvents and modelEvents[field.key]
            parts2[#parts2 + 1] = tostring(field.key) .. "=" .. tostring(v == nil and "<nil>" or v)
          end
        end
        pcall(Log.emit, "rfsuite", "onSave[" .. sectionKey .. "]: model.audio_events " .. table.concat(parts2, ",")
          .. " store=" .. tostring(modelEvents ~= nil)
          .. " written=" .. tostring(modelDirty)
          .. " ok=" .. tostring(modelOk)
          .. (modelErr and (" err=" .. tostring(modelErr)) or ""), "debug")
      end
    end

    local ok, err = nil, nil
    if type(ctx.savePreferences) == "function" then
      ok, err = ctx.savePreferences()
    else
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: ctx.savePreferences not a function", "warn")
      end
      return false
    end

    -- Both stores, because a save is only done when both were believed.
    local errModel = false
    if ok and not modelOk then
      ok, err, errModel = false, modelErr, true
    end

    if ok then
      ui.dirty = false
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: savePreferences OK", "info")
      end
      return true
    else
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: savePreferences failed: " .. tostring(err or "?"), "error")
      end
      if ctx and type(ctx.reportSave) == "function" then
        ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"), message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(ctx.i18n, err, errModel) })
      end
      return false
    end
  end

  function page.build(ctx)
    ensureDeps()
    ensureLoaded(ctx.preferences)

    local children       = ctx.children
    local x, w          = ctx.x, ctx.w
    local i18n           = ctx.i18n
    ui.runtime.setRequestRebuild(ctx.requestRebuild)
    ui.runtime.openHelp = ctx.openHelp
    local cursorY        = ctx.y
    local helpTexts      = ROW_HELP[sectionKey](t, i18n)
    local onHelp         = getInlineHelpHandler()
    -- The number rows' closure caches, looked up at the first number row rather than per row.
    local enabledCache, getterCache, setterCache = nil, nil, nil

    -- Rows of one page share labels -- Link's six level pairs and five holds read the same two
    -- and one texts -- so each label key is translated once per build. Every row sharing a key
    -- also shares its fallback, so the first row's lookup is the one every later row would make.
    -- Per build rather than per page: the language can change while the page is open.
    local labels = {}

    Controls.appendStaticSectionHeader(children, x, cursorY, w, t(i18n, section.titleKey, section.titleFallback))
    cursorY = cursorY + Controls.STATIC_SECTION_H

    for _, item in ipairs(section.items) do
      local k = item.key
      if item.requires and ui.config[item.requires] ~= true then
        -- drawn only while the switch it qualifies is on
      else
        local labelKey = item.labelKey
        local labelText = labels[labelKey]
        if labelText == nil then
          labelText = t(i18n, item.labelKey, item.labelFallback)
          labels[labelKey] = labelText
        end
        if item.kind == "subheader" then
          cursorY = cursorY + 10
          Controls.appendStaticSectionHeader(children, x, cursorY, w, labelText)
          cursorY = cursorY + Controls.STATIC_SECTION_H
        elseif item.kind == "choice" then
          local options, selected, onSelect
          local comboOpts = nil
          if k == "fuel_callout_percent" then
            options, selected, onSelect = getFuelCalloutOptions(i18n), getFuelCalloutGetter()(), getFuelCalloutSetter()
          elseif k == "fuel_finer_below" then
            options, selected, onSelect = getFuelFinerBelowOptions(i18n), getFuelFinerBelowGetter()(), getFuelFinerBelowSetter()
          elseif k == "fuel_finer_step" then
            options, selected, onSelect = getFuelFinerStepOptions(i18n), getFuelFinerStepGetter()(), getFuelFinerStepSetter()
            -- Its own options table rather than helpOpts', which is nil without a help text and
            -- would take the greying with it.
            local helpText = helpTexts[k]
            if type(helpText) ~= "string" or helpText == "" then helpText = nil end
            comboOpts = {
              active = fuelFinerActive,
              helpText = helpText,
              helpTitle = helpText and labelText,
              onHelp = helpText and onHelp
            }
          elseif k == "voltage_announce" then
            options, selected, onSelect = getAnnounceOptions(i18n), getAnnounceGetter()(), getAnnounceSetter()
          elseif k == "tpwr_max" then
            options, selected, onSelect = getTxPowerMaxOptions(), getTxPowerMaxGetter()(), getTxPowerMaxSetter()
          else
            options, selected, onSelect = getRepeatOptions(i18n), getRepeatGetter(k)(), getRepeatSetter(k, item.enabledBy)
          end
          cursorY = cursorY + Controls.appendComboSelect(
            children, x, cursorY, w,
            labelText,
            options,
            selected,
            onSelect,
            comboOpts or helpOpts(helpTexts, k, labelText, onHelp)
          )
        elseif item.kind == "number" then
          if not getterCache then
            enabledCache = numberCache("numberEnabled")
            getterCache = numberCache("numberGetters")
            setterCache = numberCache("numberSetters")
          end
          local field = SCHEMA_BY_KEY[k]
          local minVal = (field and field.min) or 0
          local maxVal = (field and field.max) or 100
          labelText = modelScopeLabel(i18n, k, labelText)
          local display = nil
          if item.temperature and usesFahrenheit(ctx.preferences) then display = fahrenheitText end
          -- The `?` fields go straight into the control's options, as helpOpts would set them.
          local helpText = helpTexts[k]
          if type(helpText) ~= "string" or helpText == "" then helpText = nil end
          cursorY = cursorY + Controls.appendNumberField(
            children, x, cursorY, w,
            labelText,
            {
              enabled = getNumberEnabled(enabledCache, item.enabledBy),
              min = minVal,
              max = maxVal,
              step = item.step,
              suffix = item.suffix or "",
              display = display,
              get = getNumberGetter(getterCache, k, minVal, maxVal),
              set = getNumberSetter(setterCache, k, item.enabledBy, minVal, maxVal),
              helpText = helpText,
              helpTitle = helpText and labelText,
              onHelp = helpText and onHelp
            }
          )
        elseif item.kind == "bool" and k == "fuel_haptic_below_zero" then
          cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
            labelText,
            getFuelHapticGetter(),
            getFuelHapticSetter(),
            helpOpts(helpTexts, k, labelText, onHelp)
          )
        else
          cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
            labelText,
            ui.runtime.getBoolGetter(k),
            ui.runtime.getBoolSetter(k),
            helpOpts(helpTexts, k, labelText, onHelp)
          )
        end
      end
    end
  end

  function page.onClose()
    if type(ui.runtime) == "table" then
      setmetatable(ui.runtime, nil)
    end
    if Common then
      Common.resetPageState(ui, {
        tablesToWipe = { "runtime" }
      })
    end
    ui.runtimeBase = nil
    Controls = nil
    Common = nil
    t = nil
  end

  -- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
  function page.hasUnsavedChanges()
    return ui.dirty == true
  end

  return page
end

return M
