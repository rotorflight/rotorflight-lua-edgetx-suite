-- The flight controller's adjustment functions, and the channel geometry that reaches them.
--
-- Rotorflight drives its stepped adjustments from two RC channels: one arms a slot (the enable
-- channel) and one carries the step (the value channel). fc/rc_adjustments.c accepts a step only
-- after the value channel has stood still inside one window for TRIGGER_DELAY, so every control
-- on the tuning screen is a PULSE to a fixed magnitude and never a movement.
--
-- Nothing in this file probes. It is a table and arithmetic, so the widget pass, a reactive
-- closure and a settings page can all read it.

local M = {}

-- Their packager rewrites every t(<key>, <fallback>) call site with a literal widgets.dashboard key into
-- the locale being built (bin/package/build_package.py, .vscode/scripts/precompile_i18n.py). In a
-- tree that has not been packaged the call survives and answers with its own English fallback,
-- which is what the simulator and the offline accounting run see.
local function t(_key, fallback)
  return fallback
end

-- Every adjustment function the firmware exposes, with the value range their own adjustments
-- page uses. Where the firmware's own adjustment table (fc/rc_adjustments.c, ADJ_ENTRY) allows
-- a wider range, fwMin/fwMax carry it: a board value is only refused outside the firmware's range,
-- while the narrower pair stays the one the standard slots are written with. The names are the
-- ones that page shows, so a parameter reads the same wherever the pilot meets it
-- (app/pages/setup/controls/adjustments/page.lua, ADJUST_FUNCTIONS).
--
-- `cmd`, `api` and `field` say where the CURRENT value of that parameter lives: the MSP command
-- that answers it, the module under tasks/msp/api that decodes the reply, and the name that
-- module's parse gives the value. The overlay reads a value once, on the ground, and then follows
-- it through the board's own AdjF/AdjV report -- those two sensors carry the last adjustment that
-- fired and nothing else, so without this table a parameter would only have a number on screen
-- after the pilot had already turned it.
--
-- Ids 30 and 31 are deliberately absent: YAW_COLLECTIVE_DYN and YAW_COLLECTIVE_DECAY have no
-- ADJ_ENTRY in 4.6 firmware, so a slot naming them can never fire and a row offering them would
-- promise a step that is not made. Id 4, OSD_PROFILE, has a command and no field: their
-- osd_config parse stops before the profile byte, so nothing here can read that one back.
M.FUNCTIONS = {
  { id = 1, name = t("widgets.dashboard.fn_rate_profile", "Rate Profile"), min = 1, max = 6,
    cmd = 101, api = "status", field = "current_control_rate_profile_index" },
  { id = 2, name = t("widgets.dashboard.fn_pid_profile", "PID Profile"), min = 1, max = 6,
    cmd = 101, api = "status", field = "current_pid_profile_index" },
  { id = 3, name = t("widgets.dashboard.fn_led_profile", "LED Profile"), min = 1, max = 4,
    cmd = 150, api = "led_strip_settings", field = "ledstrip_profile" },
  { id = 4, name = t("widgets.dashboard.fn_osd_profile", "OSD Profile"), min = 1, max = 3,
    cmd = 84, api = nil, field = nil },
  { id = 5, name = t("widgets.dashboard.fn_pitch_rate", "Pitch Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rates_2" },
  { id = 6, name = t("widgets.dashboard.fn_roll_rate", "Roll Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rates_1" },
  { id = 7, name = t("widgets.dashboard.fn_yaw_rate", "Yaw Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rates_3" },
  { id = 8, name = t("widgets.dashboard.fn_pitch_rc_rate", "Pitch RC Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rcRates_2" },
  { id = 9, name = t("widgets.dashboard.fn_roll_rc_rate", "Roll RC Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rcRates_1" },
  { id = 10, name = t("widgets.dashboard.fn_yaw_rc_rate", "Yaw RC Rate"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "rcRates_3" },
  { id = 11, name = t("widgets.dashboard.fn_pitch_rc_expo", "Pitch RC Expo"), min = 0, max = 100,
    cmd = 111, api = "rc_tuning", field = "rcExpo_2" },
  { id = 12, name = t("widgets.dashboard.fn_roll_rc_expo", "Roll RC Expo"), min = 0, max = 100,
    cmd = 111, api = "rc_tuning", field = "rcExpo_1" },
  { id = 13, name = t("widgets.dashboard.fn_yaw_rc_expo", "Yaw RC Expo"), min = 0, max = 100,
    cmd = 111, api = "rc_tuning", field = "rcExpo_3" },
  { id = 14, name = t("widgets.dashboard.fn_pitch_p", "Pitch P-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_P" },
  { id = 15, name = t("widgets.dashboard.fn_pitch_i", "Pitch I-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_I" },
  { id = 16, name = t("widgets.dashboard.fn_pitch_d", "Pitch D-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_D" },
  { id = 17, name = t("widgets.dashboard.fn_pitch_f", "Pitch F-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_F" },
  { id = 18, name = t("widgets.dashboard.fn_roll_p", "Roll P-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_P" },
  { id = 19, name = t("widgets.dashboard.fn_roll_i", "Roll I-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_I" },
  { id = 20, name = t("widgets.dashboard.fn_roll_d", "Roll D-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_D" },
  { id = 21, name = t("widgets.dashboard.fn_roll_f", "Roll F-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_F" },
  { id = 22, name = t("widgets.dashboard.fn_yaw_p", "Yaw P-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_2_P" },
  { id = 23, name = t("widgets.dashboard.fn_yaw_i", "Yaw I-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_2_I" },
  { id = 24, name = t("widgets.dashboard.fn_yaw_d", "Yaw D-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_2_D" },
  { id = 25, name = t("widgets.dashboard.fn_yaw_f", "Yaw F-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_2_F" },
  { id = 26, name = t("widgets.dashboard.fn_yaw_cw_stop_gain", "Yaw CW Stop Gain"), min = 25, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_cw_stop_gain" },
  { id = 27, name = t("widgets.dashboard.fn_yaw_ccw_stop_gain", "Yaw CCW Stop Gain"), min = 25, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_ccw_stop_gain" },
  { id = 28, name = t("widgets.dashboard.fn_yaw_cyclic_ff", "Yaw Cyclic Precomp"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_cyclic_ff_gain" },
  { id = 29, name = t("widgets.dashboard.fn_yaw_collective_ff", "Yaw Collective Precomp"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_collective_ff_gain" },
  { id = 32, name = t("widgets.dashboard.fn_pitch_collective_ff", "Pitch Collective Precomp"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "pitch_collective_ff_gain" },
  { id = 33, name = t("widgets.dashboard.fn_pitch_gyro_cutoff", "Pitch Gyro Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "gyro_cutoff_1" },
  { id = 34, name = t("widgets.dashboard.fn_roll_gyro_cutoff", "Roll Gyro Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "gyro_cutoff_0" },
  { id = 35, name = t("widgets.dashboard.fn_yaw_gyro_cutoff", "Yaw Gyro Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "gyro_cutoff_2" },
  { id = 36, name = t("widgets.dashboard.fn_pitch_dterm_cutoff", "Pitch D-term Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "dterm_cutoff_1" },
  { id = 37, name = t("widgets.dashboard.fn_roll_dterm_cutoff", "Roll D-term Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "dterm_cutoff_0" },
  { id = 38, name = t("widgets.dashboard.fn_yaw_dterm_cutoff", "Yaw D-term Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "dterm_cutoff_2" },
  { id = 39, name = t("widgets.dashboard.fn_rescue_climb_collective", "Rescue Climb Collective"), min = 0, max = 1000,
    cmd = 146, api = "rescue_profile", field = "rescue_climb_collective" },
  { id = 40, name = t("widgets.dashboard.fn_rescue_hover_collective", "Rescue Hover Collective"), min = 0, max = 1000,
    cmd = 146, api = "rescue_profile", field = "rescue_hover_collective" },
  { id = 41, name = t("widgets.dashboard.fn_rescue_hover_altitude", "Rescue Hover Altitude"), min = 0, max = 2500,
    cmd = 146, api = "rescue_profile", field = "rescue_hover_altitude" },
  { id = 42, name = t("widgets.dashboard.fn_rescue_alt_p", "Rescue Altitude P-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 146, api = "rescue_profile", field = "rescue_alt_p_gain" },
  { id = 43, name = t("widgets.dashboard.fn_rescue_alt_i", "Rescue Altitude I-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 146, api = "rescue_profile", field = "rescue_alt_i_gain" },
  { id = 44, name = t("widgets.dashboard.fn_rescue_alt_d", "Rescue Altitude D-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 146, api = "rescue_profile", field = "rescue_alt_d_gain" },
  { id = 45, name = t("widgets.dashboard.fn_angle_level_gain", "Angle Level Gain"), min = 0, max = 200,
    cmd = 94, api = "pid_profile", field = "angle_level_strength" },
  { id = 46, name = t("widgets.dashboard.fn_horizon_level_gain", "Horizon Level Gain"), min = 0, max = 200,
    cmd = 94, api = "pid_profile", field = "horizon_level_strength" },
  { id = 47, name = t("widgets.dashboard.fn_acro_trainer_gain", "Acro Trainer Gain"), min = 25, max = 255,
    cmd = 94, api = "pid_profile", field = "trainer_gain" },
  { id = 48, name = t("widgets.dashboard.fn_governor_gain", "Governor PID-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_gain" },
  { id = 49, name = t("widgets.dashboard.fn_governor_p", "Governor P-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_p_gain" },
  { id = 50, name = t("widgets.dashboard.fn_governor_i", "Governor I-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_i_gain" },
  { id = 51, name = t("widgets.dashboard.fn_governor_d", "Governor D-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_d_gain" },
  { id = 52, name = t("widgets.dashboard.fn_governor_f", "Governor F-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_f_gain" },
  { id = 53, name = t("widgets.dashboard.fn_governor_tta", "Governor TTA-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_tta_gain" },
  { id = 54, name = t("widgets.dashboard.fn_governor_cyclic_ff", "Governor Cyclic Precomp"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_cyclic_weight" },
  { id = 55, name = t("widgets.dashboard.fn_governor_collective_ff", "Governor Collective Precomp"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_collective_weight" },
  { id = 56, name = t("widgets.dashboard.fn_pitch_b", "Pitch B-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_B" },
  { id = 57, name = t("widgets.dashboard.fn_roll_b", "Roll B-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_B" },
  { id = 58, name = t("widgets.dashboard.fn_yaw_b", "Yaw B-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_2_B" },
  { id = 59, name = t("widgets.dashboard.fn_pitch_o", "Pitch O-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_1_O" },
  { id = 60, name = t("widgets.dashboard.fn_roll_o", "Roll O-gain"), min = 0, max = 250, fwMin = 0, fwMax = 1000,
    cmd = 112, api = "pid_tuning", field = "pid_0_O" },
  { id = 61, name = t("widgets.dashboard.fn_cross_coupling_gain", "Cross Coupling Gain"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "cyclic_cross_coupling_gain" },
  { id = 62, name = t("widgets.dashboard.fn_cross_coupling_ratio", "Cross Coupling Ratio"), min = 0, max = 200,
    cmd = 94, api = "pid_profile", field = "cyclic_cross_coupling_ratio" },
  { id = 63, name = t("widgets.dashboard.fn_cross_coupling_cutoff", "Cross Coupling Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "cyclic_cross_coupling_cutoff" },
  { id = 64, name = t("widgets.dashboard.fn_acc_trim_pitch", "Accelerometer Pitch Trim"), min = -300, max = 300,
    cmd = 240, api = "acc_trim", field = "pitch" },
  { id = 65, name = t("widgets.dashboard.fn_acc_trim_roll", "Accelerometer Roll Trim"), min = -300, max = 300,
    cmd = 240, api = "acc_trim", field = "roll" },
  { id = 66, name = t("widgets.dashboard.fn_yaw_inertia_precomp_gain", "Yaw Inertia Precomp Gain"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_inertia_precomp_gain" },
  { id = 67, name = t("widgets.dashboard.fn_yaw_inertia_precomp_cutoff", "Yaw Inertia Precomp Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_inertia_precomp_cutoff" },
  { id = 68, name = t("widgets.dashboard.fn_pitch_setpoint_boost_gain", "Pitch Setpoint Boost Gain"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "setpoint_boost_gain_2" },
  { id = 69, name = t("widgets.dashboard.fn_roll_setpoint_boost_gain", "Roll Setpoint Boost Gain"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "setpoint_boost_gain_1" },
  { id = 70, name = t("widgets.dashboard.fn_yaw_setpoint_boost_gain", "Yaw Setpoint Boost Gain"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "setpoint_boost_gain_3" },
  { id = 71, name = t("widgets.dashboard.fn_col_setpoint_boost_gain", "Collective Setpoint Boost Gain"), min = 0, max = 255,
    cmd = 111, api = "rc_tuning", field = "setpoint_boost_gain_4" },
  { id = 72, name = t("widgets.dashboard.fn_yaw_dyn_ceiling_gain", "Yaw Dynamic Ceiling Gain"), min = 0, max = 250,
    cmd = 111, api = "rc_tuning", field = "yaw_dynamic_ceiling_gain" },
  { id = 73, name = t("widgets.dashboard.fn_yaw_dyn_deadband_gain", "Yaw Dynamic Deadband Gain"), min = 0, max = 250,
    cmd = 111, api = "rc_tuning", field = "yaw_dynamic_deadband_gain" },
  { id = 74, name = t("widgets.dashboard.fn_yaw_dyn_deadband_filter", "Yaw Dynamic Deadband Filter"), min = 0, max = 250,
    cmd = 111, api = "rc_tuning", field = "yaw_dynamic_deadband_filter" },
  { id = 75, name = t("widgets.dashboard.fn_yaw_precomp_cutoff", "Yaw Precomp Cutoff"), min = 0, max = 250,
    cmd = 94, api = "pid_profile", field = "yaw_precomp_cutoff" },
  { id = 76, name = t("widgets.dashboard.fn_gov_idle_throttle", "Governor Idle Throttle"), min = 0, max = 250,
    cmd = 142, api = "governor_config", field = "governor_idle_throttle" },
  { id = 77, name = t("widgets.dashboard.fn_gov_auto_throttle", "Governor Auto Throttle"), min = 0, max = 250,
    cmd = 142, api = "governor_config", field = "governor_auto_throttle" },
  { id = 78, name = t("widgets.dashboard.fn_gov_max_throttle", "Governor Max Throttle"), min = 0, max = 100,
    cmd = 148, api = "governor_profile", field = "governor_max_throttle" },
  { id = 79, name = t("widgets.dashboard.fn_gov_min_throttle", "Governor Min Throttle"), min = 0, max = 100,
    cmd = 148, api = "governor_profile", field = "governor_min_throttle" },
  { id = 80, name = t("widgets.dashboard.fn_gov_headspeed", "Governor Headspeed"), min = 0, max = 10000,
    fwMin = 0, fwMax = 50000, cmd = 148, api = "governor_profile", field = "governor_headspeed" },
  { id = 81, name = t("widgets.dashboard.fn_gov_yaw_ff", "Governor Yaw F-gain"), min = 0, max = 250,
    cmd = 148, api = "governor_profile", field = "governor_yaw_weight" },
  { id = 82, name = t("widgets.dashboard.fn_battery_profile", "Battery Profile"), min = 1, max = 6,
    cmd = 175, api = "battery_profile", field = "batteryProfile" },
  { id = 83, name = t("widgets.dashboard.fn_cyclic_master_gain", "Cyclic Master Gain"), min = 25, max = 200,
    cmd = 94, api = "pid_profile", field = "cyclic_master_gain" },
  { id = 84, name = t("widgets.dashboard.fn_yaw_master_gain", "Yaw Master Gain"), min = 25, max = 200,
    cmd = 94, api = "pid_profile", field = "yaw_master_gain" }
}

local byId = {}
for i = 1, #M.FUNCTIONS do
  byId[M.FUNCTIONS[i].id] = M.FUNCTIONS[i]
end

M.BANK_COUNT = 6
M.ROW_COUNT = 6

-- Short addresses for the ground comparison when a full function name does not fit. Banks
-- remain the wire geometry; the flying surface derives groups and never draws these letters.
M.STANDARD_BANK_LABELS = { "P", "I", "D", "F", "O", "B" }

-- Which profile a parameter lives in, so that a profile change can say what it invalidated.
--
-- The firmware's adjustment functions act on the ACTIVE profile: the PID, rescue and
-- governor-profile terms follow the PID profile, the rates follow the rate profile, and a handful
-- of settings follow neither. The MSP command each value is read back with says exactly that and
-- is already in the table above, so the scope is derived from it rather than listed a second
-- time -- 112 pid_tuning, 94 pid_profile, 146 rescue_profile and 148 governor_profile follow the
-- PID profile, 111 rc_tuning follows the rate profile, and 142 governor_config, 240 acc_trim,
-- 175 battery_profile and 101 status follow neither.
M.SCOPE_PID = "pid"
M.SCOPE_RATE = "rate"
local SCOPE_BY_COMMAND = {
  [112] = M.SCOPE_PID, [94] = M.SCOPE_PID, [146] = M.SCOPE_PID, [148] = M.SCOPE_PID,
  [111] = M.SCOPE_RATE
}

--- Which profile the parameter `id` belongs to, or nil when it belongs to neither.
function M.scopeOf(id)
  local fn = byId[tonumber(id) or -1]
  if fn == nil then return nil end
  return SCOPE_BY_COMMAND[fn.cmd]
end

-- The flying list describes parameters rather than the enable windows that happen to reach
-- them. This mapping is data, independent of the slot layout and of translated names. Rates
-- share rc_tuning, the gyro/D filters share their subsystem, and the remaining axis terms keep
-- their axis even when another set puts them in a different bank.
M.GROUPS = {
  { id = "cyclic", name = t("widgets.dashboard.inflight_group_cyclic", "Cyclic") },
  { id = "roll", name = t("widgets.dashboard.inflight_group_roll", "Roll") },
  { id = "pitch", name = t("widgets.dashboard.inflight_group_pitch", "Pitch") },
  { id = "yaw", name = t("widgets.dashboard.inflight_group_yaw", "Yaw") },
  { id = "governor", name = t("widgets.dashboard.inflight_group_governor", "Governor") },
  { id = "rates", name = t("widgets.dashboard.inflight_group_rates", "Rates") },
  { id = "filter", name = t("widgets.dashboard.inflight_group_filter", "Filter") },
  { id = "cross", name = t("widgets.dashboard.inflight_group_cross", "Cross Coupling") },
  { id = "rescue", name = t("widgets.dashboard.inflight_group_rescue", "Rescue & Level") },
  { id = "acc", name = t("widgets.dashboard.inflight_group_acc", "Acc Trim") },
  { id = "other", name = t("widgets.dashboard.inflight_group_other", "Other") }
}
M.GROUP_BY_ID = {
  [5] = 6, [6] = 6, [7] = 6, [8] = 6, [9] = 6, [10] = 6, [11] = 6, [12] = 6, [13] = 6,
  [14] = 3, [15] = 3, [16] = 3, [17] = 3, [18] = 2, [19] = 2, [20] = 2, [21] = 2,
  [22] = 4, [23] = 4, [24] = 4, [25] = 4, [26] = 4, [27] = 4, [28] = 4, [29] = 4,
  [32] = 3, [33] = 7, [34] = 7, [35] = 7, [36] = 7, [37] = 7, [38] = 7,
  [39] = 9, [40] = 9, [41] = 9, [42] = 9, [43] = 9, [44] = 9, [45] = 9, [46] = 9, [47] = 9,
  [48] = 5, [49] = 5, [50] = 5, [51] = 5, [52] = 5, [53] = 5, [54] = 5, [55] = 5,
  [56] = 3, [57] = 2, [58] = 4, [59] = 3, [60] = 2, [61] = 8, [62] = 8, [63] = 8,
  [64] = 10, [65] = 10, [66] = 4, [67] = 4, [68] = 6, [69] = 6, [70] = 6, [71] = 6,
  [72] = 6, [73] = 6, [74] = 6, [75] = 4, [76] = 5, [77] = 5, [78] = 5, [79] = 5,
  [80] = 5, [81] = 5, [83] = 1, [84] = 4
}
M.SELECTORS = { [1] = true, [2] = true, [3] = true, [4] = true, [82] = true }
local termOrder = {
  [14] = 1, [15] = 2, [16] = 3, [17] = 4, [56] = 5, [59] = 6,
  [18] = 1, [19] = 2, [20] = 3, [21] = 4, [57] = 5, [60] = 6,
  [22] = 1, [23] = 2, [24] = 3, [25] = 4, [58] = 5,
  [49] = 1, [50] = 2, [51] = 3, [52] = 4
}
local functionOrder = {}
for index = 1, #M.FUNCTIONS do functionOrder[M.FUNCTIONS[index].id] = index end

function M.groupOf(id)
  return M.GROUP_BY_ID[id] or #M.GROUPS
end

function M.parameterOrder(id)
  return termOrder[id] or (10 + (functionOrder[id] or (1000 + id)))
end

-- An empty string means all parameters. A nonempty list is a stable, per-model list of function
-- ids, never addresses: a custom slot can move without changing the pilot's flight list. Keep
-- absent ids in the result so a changed FC table can be reported instead of silently shortening
-- the list. The store serialises scalars only, hence the comma-separated representation.
function M.flightList(stored)
  local wanted = {}
  for token in string.gmatch(stored or "", "[^,%s]+") do
    local id = tonumber(token)
    if id ~= nil and id > 0 and id == math.floor(id) then wanted[id] = true end
  end
  return wanted
end

-- Called only when the set or its geometry changes. Every entry retains the original bank/row;
-- neither grouping nor filtering writes or rearranges the FC's slot table. A one-direction cell
-- remains useful, but a cell with neither safe window is absent. Scope travels with each group
-- as a set because a subsystem such as Governor can contain both PID and global parameters.
--- The same derivation, one bank per call. It runs on a ground pass that already carries the
-- widget's whole background, which leaves room for a bank's worth of entries and not for all six
-- (measured: the whole table on one pass took a ground-read pass to about 20 700 instructions).
function M.newGroupWork(set, rowValues, bankValues, stored)
  return {
    set = set, rowValues = rowValues, bankValues = bankValues,
    wanted = M.flightList(stored), restricted = stored ~= nil and string.find(stored, "%S") ~= nil,
    indexed = {}, cells = {}, present = {}, bank = 0
  }
end

--- One step of a group derivation: a bank, or, after the last bank, the sort. Answers
-- done, groups, cells, missing.
function M.groupStep(work)
  if work.bank < M.BANK_COUNT then
    work.bank = work.bank + 1
    local bank, set, rowValues, bankValues = work.bank, work.set, work.rowValues, work.bankValues
    local rows = set and set[bank]
    if rows ~= nil and bankValues and bankValues[bank] ~= nil then
      local indexed, cells, present, wanted = work.indexed, work.cells, work.present, work.wanted
      for row = 1, M.ROW_COUNT do
        local id = rows[row]
        local up = M.rowCode(row, true, rowValues, bank)
        local down = M.rowCode(row, false, rowValues, bank)
        if id ~= nil and not M.SELECTORS[id] and (up ~= nil or down ~= nil) then
          present[id] = true
          if not work.restricted or wanted[id] then
            local index = M.groupOf(id)
            local group = indexed[index]
            if group == nil then
              group = { index = index, id = M.GROUPS[index].id, name = M.GROUPS[index].name, entries = {}, scopes = {} }
              indexed[index] = group
            end
            local scope = M.scopeOf(id)
            group.scopes[scope or "global"] = true
            -- The sort key and the shown name are computed once per entry, not per comparison.
            local name, title = M.nameOf(id), group.name
            if #name > #title + 1 and string.sub(name, 1, #title + 1) == title .. " " then
              name = string.sub(name, #title + 2)
            end
            local entry = { id = id, name = name, bank = bank, row = row, scope = scope,
              order = M.parameterOrder(id), up = up ~= nil, down = down ~= nil }
            group.entries[#group.entries + 1] = entry
            cells[bank] = cells[bank] or {}
            cells[bank][row] = entry
          end
        end
      end
    end
    return false
  end
  local groups, indexed = {}, work.indexed
  for index = 1, #M.GROUPS do
    local group = indexed[index]
    if group ~= nil then
      table.sort(group.entries, function(a, b)
        local first, second = a.order, b.order
        if first ~= second then return first < second end
        if a.bank ~= b.bank then return a.bank < b.bank end
        return a.row < b.row
      end)
      groups[#groups + 1] = group
      for i = 1, #group.entries do
        group.entries[i].group, group.entries[i].index = #groups, i
      end
    end
  end
  local missing = {}
  for id in pairs(work.wanted) do if not work.present[id] then missing[#missing + 1] = id end end
  table.sort(missing)
  return true, groups, work.cells, missing
end

--- The groups a flight list keeps, from the unfiltered groups of the board. An empty or absent
-- list keeps everything and costs nothing; a list copies only the entries it keeps, so their
-- group and index fields describe the filtered view and not the board's. `missing` names listed
-- ids the board does not carry.
function M.filterGroups(all, stored)
  local wanted = M.flightList(stored)
  if next(wanted) == nil then
    local cells = {}
    for _, group in ipairs(all) do
      for _, entry in ipairs(group.entries) do
        cells[entry.bank] = cells[entry.bank] or {}
        cells[entry.bank][entry.row] = entry
      end
    end
    return all, cells, {}
  end
  local groups, cells, present = {}, {}, {}
  for _, group in ipairs(all) do
    local kept
    for _, entry in ipairs(group.entries) do
      present[entry.id] = true
      if wanted[entry.id] then
        if kept == nil then
          kept = { index = group.index, id = group.id, name = group.name, entries = {}, scopes = group.scopes }
          groups[#groups + 1] = kept
        end
        local copy = { id = entry.id, name = entry.name, bank = entry.bank, row = entry.row, scope = entry.scope,
          order = entry.order, up = entry.up, down = entry.down, group = #groups, index = #kept.entries + 1 }
        kept.entries[#kept.entries + 1] = copy
        cells[copy.bank] = cells[copy.bank] or {}
        cells[copy.bank][copy.row] = copy
      end
    end
  end
  local missing = {}
  for id in pairs(wanted) do if not present[id] then missing[#missing + 1] = id end end
  table.sort(missing)
  return groups, cells, missing
end

function M.deriveGroups(set, rowValues, bankValues, stored)
  local work = M.newGroupWork(set, rowValues, bankValues, stored)
  while true do
    local done, groups, cells, missing = M.groupStep(work)
    if done then return groups, cells, missing end
  end
end

--- The name shown under its group's title. The Configurator's names begin with the axis or the
-- subsystem (*Governor P-gain*), which the title above the list already says, so a name that
-- starts with its group's title is shown without it. Speech keeps the whole name.
function M.shortName(id)
  local name = M.nameOf(id)
  local group = M.GROUPS[M.groupOf(id)]
  local title = group and group.name
  if type(title) == "string" and #name > #title + 1 and string.sub(name, 1, #title + 1) == title .. " " then
    return string.sub(name, #title + 2)
  end
  return name
end

-- The eight parameter commands are bracketed by STATUS. A switch moved during the read must
-- not bind a session to values from two profiles, and the last STATUS confirms the first pair.
-- LED and OSD profile selectors have no tuning value to read on this route.
M.VALUE_READS = { 101, 112, 111, 94, 148, 142, 146, 240, 175, 101 }

local commandIndex = nil

--- Which api module answers `cmd`, and which of its parsed fields belongs to which function id.
--
-- Built on first use and kept afterwards: only the ground prime ever wants this index, and a
-- widget whose pilot never primes must not pay for building it. The entries are the rows of
-- M.FUNCTIONS themselves rather than copies, so the index costs one list per command and no
-- tables at all per function.
function M.fieldsForCommand(cmd)
  if commandIndex == nil then
    commandIndex = {}
    for i = 1, #M.FUNCTIONS do
      local fn = M.FUNCTIONS[i]
      if fn.cmd ~= nil and fn.api ~= nil and fn.field ~= nil then
        local entry = commandIndex[fn.cmd]
        if entry == nil then
          entry = { api = fn.api, fields = {} }
          commandIndex[fn.cmd] = entry
        end
        entry.fields[#entry.fields + 1] = fn
      end
    end
  end
  local entry = commandIndex[tonumber(cmd) or -1]
  if entry == nil then return nil, nil end
  return entry.api, entry.fields
end

--- The adjustment function with this id, or nil when the firmware has none.
function M.byId(id)
  return byId[tonumber(id) or -1]
end

--- What a parameter is called on screen. An id with no entry is named by its number rather than
-- left blank: an unnamed row the pilot is about to turn is worse than an ugly one.
function M.nameOf(id)
  local fn = byId[tonumber(id) or -1]
  if fn then return fn.name end
  return t("widgets.dashboard.fn_unknown", "Function") .. " " .. tostring(math.floor(tonumber(id) or 0))
end

-- The six enable windows of the documented radio setup, in slot order, on the bank channel.
-- Source: the project's own generic radio setup and the model template shipped beside it.
M.REFERENCE_BANDS = {
  { min = 900, max = 1100 },
  { min = 1100, max = 1300 },
  { min = 1300, max = 1400 },
  { min = 1550, max = 1700 },
  { min = 1750, max = 1900 },
  { min = 1950, max = 2100 }
}

-- The six INCREMENT windows on the value channel, row 1 at the top of the travel. A row's
-- decrement window is this window mirrored about 1500.
M.REFERENCE_ROW_WINDOWS = {
  { min = 1925, max = 1975 },
  { min = 1850, max = 1900 },
  { min = 1775, max = 1825 },
  { min = 1700, max = 1750 },
  { min = 1625, max = 1675 },
  { min = 1550, max = 1600 }
}

-- bank -> row -> adjustment function id, for the documented setup. A cell with no slot behind it
-- is simply absent, and the screen shows it as unassigned rather than as a parameter it cannot
-- drive. Replaced by the board's own slot table once the overlay has read it.
M.REFERENCE_SET = {
  [1] = { [1] = 14, [2] = 18, [3] = 22, [4] = 49, [5] = 27, [6] = 26 },
  [2] = { [1] = 15, [2] = 19, [3] = 23, [4] = 50, [5] = 28, [6] = 29 },
  [3] = { [1] = 16, [2] = 20, [3] = 24, [4] = 51, [5] = 39, [6] = 40 },
  [4] = { [1] = 17, [2] = 21, [3] = 25, [4] = 52 },
  [5] = { [1] = 59, [2] = 60, [3] = 54, [4] = 55 },
  [6] = { [1] = 56, [2] = 57, [3] = 58, [4] = 48 }
}

-- What a global variable is worth on the wire. A mixer line MAX x GVn at full weight puts
-- 1500 + 5.12 x GV microseconds on the channel, so this constant is what converts between the
-- window the firmware watches and the number written into the variable.
local US_PER_GVAR_UNIT = 5.12
local CENTRE_US = 1500

-- A channel cannot leave its own travel. At 100% output the mixer reaches 1500 +/- 512
-- microseconds, so a global variable past +/-100 moves nothing further and the output limit
-- clips it. Every band value below is therefore held inside that range.
local GVAR_TRAVEL_LIMIT = 100

local function roundToInt(value)
  return math.floor(value + 0.5)
end

--- Which band a microsecond reading falls in, or nil when it sits between two windows.
-- Used for the DISPLAY of the armed bank, so a six-position switch wired straight to the enable
-- channel reads correctly without the overlay having written anything at all.
function M.usToBand(us, bands)
  us = tonumber(us)
  if us == nil or type(bands) ~= "table" then return nil end
  for i = 1, #bands do
    local band = bands[i]
    if type(band) == "table" and us >= band.min and us <= band.max then return i end
  end
  return nil
end

--- The global variable value that parks the enable channel in the middle of one band.
-- Mid-band rather than an edge, so switch, mixer and receiver tolerance all fit inside the window.
function M.bandMidGv(band)
  if type(band) ~= "table" then return nil end
  local mid = (tonumber(band.min) or 0) + (tonumber(band.max) or 0)
  local value = roundToInt(((mid / 2) - CENTRE_US) / US_PER_GVAR_UNIT)
  if value > GVAR_TRAVEL_LIMIT then value = GVAR_TRAVEL_LIMIT end
  if value < -GVAR_TRAVEL_LIMIT then value = -GVAR_TRAVEL_LIMIT end
  return value
end

--- The value-channel magnitude that lands inside row `row`'s increment or decrement window.
-- Custom layouts supply a bank/row map compiled from both windows of the board's own slots.
-- A missing custom entry is not a request to fall back to the standard ladder.
-- The rows are 15 percent apart and row 1 is the outermost, which is exactly what the shipped
-- template's summed trims produce: 90, 75, 60, 45, 30, 15.
function M.rowCode(row, up, rowValues, bank)
  if rowValues ~= nil then
    local rows = rowValues[bank]
    local values = rows and rows[row]
    if values == nil then return nil end
    if up then return values.up end
    return values.down
  end
  row = tonumber(row)
  if row == nil or row < 1 or row > M.ROW_COUNT then return nil end
  local magnitude = (M.ROW_COUNT + 1 - row) * 15
  if up then return magnitude end
  return -magnitude
end

-- The widest window the flight controller reads at all: range steps of -125..125, five
-- microseconds each (fc/rc_modes.h, isRangeUsable). A slot whose window reaches past that is
-- never active whatever the channel carries, so a value aimed at it would step nothing.
local FIRMWARE_WINDOW_MIN_US = 875
local FIRMWARE_WINDOW_MAX_US = 2125

--- A window's microsecond bounds as the flight controller reads them, or nil for a window it
-- never reads: malformed, empty, reversed, or reaching past the range above.
function M.windowBounds(window)
  if type(window) ~= "table" then return nil end
  local low, high = tonumber(window.start), tonumber(window["end"])
  if low == nil or high == nil or low >= high then return nil end
  if low < FIRMWARE_WINDOW_MIN_US or high > FIRMWARE_WINDOW_MAX_US then return nil end
  return low, high
end

--- The channel value, in microseconds, that a global variable value puts on the wire.
function M.gvarToUs(value)
  return CENTRE_US + value * US_PER_GVAR_UNIT
end

--- A step value inside the board's window, or nil if the mixer cannot reach it.
-- Increment and decrement windows are independent; a custom decrement need not mirror the
-- increment about centre. Never let clamping turn an unreachable window into another row.
function M.windowCode(window)
  local low, high = M.windowBounds(window)
  if low == nil then return nil end
  local value = M.bandMidGv({ min = low, max = high })
  local us = M.gvarToUs(value)
  if value == 0 or us < low or us >= high then return nil end
  return value
end

--- A raw channel reading, as microseconds. EdgeTX answers getValue("chN") on -1024..1024 around
-- centre; the flight controller and every window above speak microseconds. The input is always
-- raw: positive raw values overlap the microsecond band and cannot be distinguished by magnitude.
--
-- The factor is a HALF, not 500/1024. A channel at its mechanical limit is 1024 raw and 2012 us
-- on the wire -- 512 us either side of centre, which is what the radio sends and what the flight
-- controller measures -- so 500/1024 is short by 12 us at full travel and by proportionally less
-- everywhere else. It matters here because every reading this returns is tested against an
-- adjustment window, and the documented windows are 50 us wide with 25 us gaps between them:
-- a reading that is 12 us out is a reading that can name the wrong window at its edges.
function M.channelRawToUs(raw)
  raw = tonumber(raw)
  if raw == nil then return nil end
  if raw >= -1200 and raw <= 1200 then
    return roundToInt(CENTRE_US + (raw * 0.5))
  end
  return nil
end

-- The band values of the documented setup, computed from the windows above rather than written
-- out again, so the two can never disagree.
M.REFERENCE_BAND_GV = {}
for i = 1, #M.REFERENCE_BANDS do
  M.REFERENCE_BAND_GV[i] = M.bandMidGv(M.REFERENCE_BANDS[i])
end


-- ---------------------------------------------------------------------------
-- The receiver map, and which wire channel an adjustment slot's field names
-- ---------------------------------------------------------------------------

-- Their adjustments page bounds an AUX field to this before it maps it (its AUX_CHANNEL_COUNT):
-- MAX_SUPPORTED_RC_CHANNEL_COUNT 18 less CONTROL_CHANNEL_COUNT 5, so AUX1..AUX13 as fields 0..12.
local AUX_FIELD_COUNT = 13

-- The first AUX member: four sticks and the throttle ahead of it, 0-based. This is the firmware's
-- CONTROL_CHANNEL_COUNT (rx/rx.h), the same five `rc_adjustments.c` adds to an adjustment's field.
local AUX_MEMBER_BASE = 5

-- How many AUX fields the receiver map has anything to say about. The map is
-- RX_MAPPABLE_CHANNEL_COUNT = 8 bytes long (target/common_defaults_post.h, served whole by
-- MSP_RX_MAP), five of them the sticks, so it names AUX1, AUX2 and AUX3 and stops.
local MAPPED_AUX_COUNT = 3

M.AUX_FIELD_COUNT = AUX_FIELD_COUNT
M.AUX_MEMBER_BASE = AUX_MEMBER_BASE
M.MAPPED_AUX_COUNT = MAPPED_AUX_COUNT

--- The wire channel an AUX field of a slot record names.
--
-- The record's field is a 0-based index into the AUX channels, and the firmware reads it as
-- `rcInput[field + CONTROL_CHANNEL_COUNT]` with a count of five (fc/rc_adjustments.c, rx/rx.h).
-- So the field names a position in `rcInput`, and the question is only which wire channel the
-- receiver put there.
--
-- The receiver map answers that for the FIRST EIGHT positions and for no others.
-- `readRxChannels` (rx/rx.c) takes the sample for position `channel` from wire channel
-- `rcmap[channel]` while `channel < RX_MAPPABLE_CHANNEL_COUNT`, which is 8, and from `channel`
-- itself above it -- and MSP_RX_MAP serves exactly those eight bytes. Positions 5, 6 and 7 are
-- the AUX1..AUX3 the map's last three bytes name; position 8 and up carry the wire channel of
-- the same number, whatever the map says about the sticks.
--
-- Fields 0..2 therefore go through the map and fields 3 and up are the identity, which is where
-- extrapolating `map.aux1 + index` past AUX3 goes wrong. Measured on a board whose map is
-- `AECR1T23` (`aux1 = 4`): the documented layout's enable field 5 and value field 6 came out as
-- CH10 and CH11 instead of CH11 and CH12, no slot matched the channels the model devotes to the
-- pair, and the board's own slot table was discarded in favour of the documented one.
--
-- The return is 1-based, the way "ch11" is spelled.
function M.auxToWireChannel(auxField, map)
  local index = math.floor(tonumber(auxField) or 0)
  if index < 0 or index >= AUX_FIELD_COUNT then return nil end

  local member = nil
  if type(map) == "table" and index < MAPPED_AUX_COUNT then
    if index == 0 then member = tonumber(map.aux1) end
    if index == 1 then member = tonumber(map.aux2) end
    if index == 2 then member = tonumber(map.aux3) end
  end
  if member == nil then member = AUX_MEMBER_BASE + index end
  return member + 1
end

--- The inverse: which field a slot record has to carry so that it watches wire channel `wire`.
--
-- The mapped positions are tried FIRST and the identity only afterwards, because that is the
-- order the firmware resolves them in: a receiver map naming a high wire channel as AUX1 makes
-- position 5 read that channel, and the position of the same number reads it as well. Both would
-- fire, and the mapped one is the one the map was written for.
--
-- Answers nil when no field reaches that channel -- a channel below the first AUX member, or one
-- past the thirteen a slot record can index. A write derived from a refused field would be a
-- write onto a slot watching some other channel entirely, so the caller is expected to refuse
-- rather than to fall back.
function M.wireToAuxField(wire, map)
  local wire0 = math.floor(tonumber(wire) or 0) - 1
  if wire0 < 0 then return nil end
  if type(map) == "table" then
    if tonumber(map.aux1) == wire0 then return 0 end
    if tonumber(map.aux2) == wire0 then return 1 end
    if tonumber(map.aux3) == wire0 then return 2 end
  end
  local field = wire0 - AUX_MEMBER_BASE
  if field < MAPPED_AUX_COUNT then return nil end
  if field > (AUX_FIELD_COUNT - 1) then return nil end
  return field
end

-- ---------------------------------------------------------------------------
-- The standard set: the documented layout with its six empty cells filled
-- ---------------------------------------------------------------------------

-- bank -> row -> adjustment function id.
--
-- The first four rows of every bank and all six rows of the first three banks are the documented
-- layout above, UNCHANGED, so a flight controller set up by hand from the project's own generic
-- radio setup carries a subset of this and nothing it carries contradicts it. What is added is
-- the six cells that setup leaves empty: the two yaw precompensation terms beside the F gains,
-- the two cross-coupling terms beside the O gains, and the head speed and the tail-torque gain
-- beside the governor's own.
M.STANDARD_SET = {
  [1] = { [1] = 14, [2] = 18, [3] = 22, [4] = 49, [5] = 27, [6] = 26 },
  [2] = { [1] = 15, [2] = 19, [3] = 23, [4] = 50, [5] = 28, [6] = 29 },
  [3] = { [1] = 16, [2] = 20, [3] = 24, [4] = 51, [5] = 39, [6] = 40 },
  [4] = { [1] = 17, [2] = 21, [3] = 25, [4] = 52, [5] = 66, [6] = 75 },
  [5] = { [1] = 59, [2] = 60, [3] = 54, [4] = 55, [5] = 61, [6] = 63 },
  [6] = { [1] = 56, [2] = 57, [3] = 58, [4] = 48, [5] = 80, [6] = 53 }
}

-- What a slot of the standard set carries as its step and its bounds.
--
-- Every cell carries the range of its own function from the table at the top of this file as its
-- bounds. The documented `adjfunc` lines say `10 200`, but fc/rc_adjustments.c constrains every
-- stepped result into the slot's adjMin..adjMax, so a parameter standing outside that band
-- jumped to its edge on the first press: a rescue hover collective of 600 fell to 200 in one
-- step, a D gain of 0 rose to 10. A press is one step and nothing else, so no cell may carry a
-- band narrower than the values its parameter can hold. A board written from the documented
-- lines therefore compares as different and is offered the write.
--
-- THE STEP IS THE PILOT'S, not this table's. It used to be part of the record -- 5 for the
-- documented thirty and 10 for the head speed -- and the pilot's ruling after the third radio
-- round is that ONE setting decides it for the slots the setup action writes. So the numbers
-- below carry bounds only, and `M.DEFAULT_STEP` is what a caller that names no step gets: the
-- documented 5, so a caller written before the setting existed still asks for the documented
-- line.
--
-- ONE PARAMETER IS NOT ON THAT SETTING. The head speed's range is 0..10000 where the gains of the
-- set reach a few hundred at most, so a step chosen to make a gain move by a feelable amount is useless on
-- it: five rpm a press is two thousand presses across the range. It carries a SECOND setting of
-- its own, on its own rungs, reaching that one function and no other cell of the set --
-- `M.DEFAULT_HEADSPEED_STEP` is what a caller that names none gets.
M.DEFAULT_STEP = 5
M.DEFAULT_HEADSPEED_STEP = 50

-- The one function of the set that takes the head speed's step. Named as a FUNCTION rather than
-- matched on the bank and row it sits in: the wide range belongs to the function, and the cell it
-- occupies is a property of a layout that could be rearranged.
M.HEADSPEED_FUNCTION = 80

--- The bounds a standard-set cell carries: its function's own range, or nil for an id the
-- firmware does not have.
function M.standardLimits(id)
  local fn = byId[tonumber(id) or -1]
  if fn == nil then return nil end
  return { min = fn.min, max = fn.max }
end

-- Which slot of the board's table each cell of the standard set is written to, in order, starting
-- at M.STANDARD_FIRST_SLOT.
--
-- The DOCUMENTED thirty come first and in the documented order -- bank by bank, row by row, with
-- the six cells that layout leaves empty simply not there -- so each of them lands on the very
-- slot index the documentation gives it and a written board matches it line for line, index
-- included. The six added cells follow, in the same bank-major order, on the six slots after the
-- documented thirty. Laying all thirty-six out bank-major from slot 2 instead would move twelve
-- of the documented lines onto other slot numbers for no gain.
M.STANDARD_FIRST_SLOT = 2
M.STANDARD_SLOT_ORDER = {
  { 1, 1 }, { 1, 2 }, { 1, 3 }, { 1, 4 }, { 1, 5 }, { 1, 6 },
  { 2, 1 }, { 2, 2 }, { 2, 3 }, { 2, 4 }, { 2, 5 }, { 2, 6 },
  { 3, 1 }, { 3, 2 }, { 3, 3 }, { 3, 4 }, { 3, 5 }, { 3, 6 },
  { 4, 1 }, { 4, 2 }, { 4, 3 }, { 4, 4 },
  { 5, 1 }, { 5, 2 }, { 5, 3 }, { 5, 4 },
  { 6, 1 }, { 6, 2 }, { 6, 3 }, { 6, 4 },
  { 4, 5 }, { 4, 6 },
  { 5, 5 }, { 5, 6 },
  { 6, 5 }, { 6, 6 }
}

-- The two windows of a row are mirror images about the channel centre, so a decrement window is
-- this less the increment window's own edges.
local MIRROR_US = CENTRE_US * 2

local NO_STEPS = {}

--- Which of the two steps a function takes, out of the pair a caller named.
--
-- `steps` is `{ step = ..., step_headspeed = ... }`, or nothing at all for a caller that names
-- neither, and each half falls back on its own default independently -- so naming one of the two
-- does not silently move the other. Resolved from the FUNCTION and not from the slot, so the
-- answer does not depend on where in the set the cell happens to sit.
local function stepFor(id, steps)
  if type(steps) ~= "table" then steps = NO_STEPS end
  if id == M.HEADSPEED_FUNCTION then
    return math.floor(tonumber(steps.step_headspeed) or M.DEFAULT_HEADSPEED_STEP)
  end
  return math.floor(tonumber(steps.step) or M.DEFAULT_STEP)
end

--- What the standard set says a cell has to hold, in the shape
-- tasks/msp/api/get_adjustment_range.lua decodes a record into.
--
-- One shape for both jobs on purpose: the comparison holds this against what the board answered,
-- and the writer encodes this into the fifteen bytes MSP 53 takes. A second spelling of the same
-- record would be a second place for the two to drift apart.
function M.standardRecord(bank, row, enaField, adjField, steps)
  local id = (M.STANDARD_SET[bank] or {})[row]
  if id == nil then return nil end
  local band = M.REFERENCE_BANDS[bank]
  local inc = M.REFERENCE_ROW_WINDOWS[row]
  if band == nil or inc == nil then return nil end
  local limits = M.standardLimits(id)
  if limits == nil then return nil end
  return {
    adjFunction = id,
    enaChannel = enaField,
    enaRange = { start = band.min, ["end"] = band.max },
    adjChannel = adjField,
    adjRange1 = { start = MIRROR_US - inc.max, ["end"] = MIRROR_US - inc.min },
    adjRange2 = { start = inc.min, ["end"] = inc.max },
    adjMin = limits.min,
    adjMax = limits.max,
    adjStep = stepFor(id, steps)
  }
end

--- The whole standard set as a list of slots, in the order they are written.
--
-- `enaField` and `adjField` are the caller's, because they come off the receiver map and nothing
-- in this file reads anything. `steps` is the pair `M.standardRecord` describes.
function M.standardSlots(enaField, adjField, steps)
  local out = {}
  for i = 1, #M.STANDARD_SLOT_ORDER do
    local cell = M.STANDARD_SLOT_ORDER[i]
    local record = M.standardRecord(cell[1], cell[2], enaField, adjField, steps)
    if record ~= nil then
      out[#out + 1] = {
        slot0 = M.STANDARD_FIRST_SLOT + i - 1,
        bank = cell[1],
        row = cell[2],
        id = record.adjFunction,
        record = record
      }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Holding a board's own table against the standard set
-- ---------------------------------------------------------------------------

local function windowsEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return (tonumber(a.start) == tonumber(b.start)) and (tonumber(a["end"]) == tonumber(b["end"]))
end

--- Whether the board's record for a slot is the record the standard set asks for.
--
-- Every field the write sets is compared and nothing else is: a record agreeing on all of them
-- behaves identically, and one that differs anywhere fires differently. Answers the first field
-- that disagrees, so a report can say WHAT differs and not only that something does.
function M.recordMatches(actual, wanted)
  if type(actual) ~= "table" or type(wanted) ~= "table" then return false, "missing" end
  if (tonumber(actual.adjFunction) or 0) ~= wanted.adjFunction then return false, "function" end
  if (tonumber(actual.enaChannel) or -1) ~= wanted.enaChannel then return false, "ena_channel" end
  if not windowsEqual(actual.enaRange, wanted.enaRange) then return false, "ena_window" end
  if (tonumber(actual.adjChannel) or -1) ~= wanted.adjChannel then return false, "adj_channel" end
  if not windowsEqual(actual.adjRange1, wanted.adjRange1) then return false, "dec_window" end
  if not windowsEqual(actual.adjRange2, wanted.adjRange2) then return false, "inc_window" end
  if (tonumber(actual.adjMin) or 0) ~= wanted.adjMin then return false, "min" end
  if (tonumber(actual.adjMax) or 0) ~= wanted.adjMax then return false, "max" end
  if (tonumber(actual.adjStep) or 0) ~= wanted.adjStep then return false, "step" end
  return true, nil
end

-- Whether a slot listens on the same channels through the same windows as the record wanted, so
-- that the wire state of that cell selects it, whatever function it holds.
local function firesOnCell(actual, wanted)
  return (tonumber(actual.enaChannel) or -1) == wanted.enaChannel
    and windowsEqual(actual.enaRange, wanted.enaRange)
    and (tonumber(actual.adjChannel) or -1) == wanted.adjChannel
    and windowsEqual(actual.adjRange1, wanted.adjRange1)
    and windowsEqual(actual.adjRange2, wanted.adjRange2)
end

--- How many slot records one pass may hold against the set. The same order of work as the
-- derivation's own slice, for the same reason: the reactive sweep of the tree standing after the
-- call comes out of the same instruction budget the call itself is billed against.
M.COMPARE_SLICE = 8

--- A comparison prepared to run a slice at a time. `records` is keyed by 1-based slot, the way
-- the ground half keeps them.
--
-- Answers nil when the configured channels have no field on this receiver map at all, which is
-- not a verdict about the board and is reported as its own state rather than as a difference.
function M.newComparison(records, map, bankChannel, valueChannel, steps)
  if type(records) ~= "table" then return nil end
  local enaField = M.wireToAuxField(bankChannel, map)
  local adjField = M.wireToAuxField(valueChannel, map)
  if enaField == nil or adjField == nil then return nil end
  return {
    records = records,
    slots = M.standardSlots(enaField, adjField, steps),
    at = 0,
    empty = 0,
    differ = 0,
    -- Slots that hold the right function on the right channels and disagree only on the step. It
    -- is counted apart from the rest because it is the one difference a SETTING on the radio can
    -- cause, and the pilot can act on "the step you chose is not the step on the board" where he
    -- cannot act on "thirty-six slots differ".
    steps = 0,
    list = {},
    -- The cells whose slot holds ANOTHER function, with the function it holds. Kept apart from
    -- `list` because these are the cells where a step lands on a parameter other than the one the
    -- row names, and the ground surface names them; every other difference it only counts.
    named = {}
  }
end

--- One slice. Answers `done, result`; `result` is nil until the last slice.
--
-- The verdict is one of three, and the empty board has one of its own because it is the case the
-- action this comparison sits beside exists for: a board carrying nothing is not a board that
-- disagrees, and telling a pilot his configuration differs in thirty-six slots when he has none
-- is an answer he cannot act on.
function M.compareStep(work, budget)
  if type(work) ~= "table" then return true, nil end
  local taken = 0
  while work.at < #work.slots do
    if budget ~= nil and taken >= budget then return false, nil end
    work.at = work.at + 1
    taken = taken + 1
    local cell = work.slots[work.at]
    local actual = work.records[cell.slot0 + 1]
    local held = 0
    if type(actual) == "table" then held = tonumber(actual.adjFunction) or 0 end
    if held == 0 then
      work.empty = work.empty + 1
      work.list[#work.list + 1] = { slot0 = cell.slot0, id = cell.id, reason = "empty" }
    else
      local ok, reason = M.recordMatches(actual, cell.record)
      if not ok then
        work.differ = work.differ + 1
        if reason == "step" then work.steps = work.steps + 1 end
        work.list[#work.list + 1] = { slot0 = cell.slot0, id = cell.id, reason = reason }
        -- recordMatches tests the function first, so a slot holding another function is always
        -- reported as that, whatever else about it differs as well. It is NAMED only where its
        -- channels and windows are the cell's own: only then does a step on that cell fire it.
        if reason == "function" and work.named ~= nil and firesOnCell(actual, cell.record) then
          work.named[#work.named + 1] = { bank = cell.bank, row = cell.row, id = cell.id, held = held }
        end
      end
    end
  end

  local total = #work.slots
  local verdict = "match"
  if total > 0 and work.empty == total then
    verdict = "empty"
  elseif (work.empty + work.differ) > 0 then
    verdict = "differ"
  end
  return true, {
    verdict = verdict,
    total = total,
    empty = work.empty,
    differ = work.differ,
    steps = work.steps,
    -- True when the ONLY thing wrong is the step, which is the case a pilot who has just changed
    -- the setting is in, and the one where the screen can name the remedy exactly.
    stepOnly = (work.steps > 0) and (work.steps == work.differ) and (work.empty == 0),
    count = work.empty + work.differ,
    slots = work.list,
    named = work.named
  }
end

--- The same verdict from the FUNCTION IDS alone, which is one reply rather than one per slot.
--
-- MSP_GET_ADJUSTMENT_FUNCTION_IDS answers every slot's function in a single forty-two byte reply,
-- and that is enough to say which slots of the set hold nothing, which hold the function the set
-- wants, and which hold a different one. What it cannot say is whether a slot holding the right
-- function watches the right channels through the right windows -- so the verdict carries
-- `idsOnly`, and every caller that shows it says what was not looked at.
--
-- `ids` is 1-based by slot, the way the reply's own parse hands it over.
function M.compareFunctionIds(ids, map, bankChannel, valueChannel, expectedSlots)
  if type(ids) ~= "table" then return nil end
  local enaField = M.wireToAuxField(bankChannel, map)
  local adjField = M.wireToAuxField(valueChannel, map)
  if enaField == nil or adjField == nil then return nil end

  -- A setup plan already holds these cells; reuse them instead of constructing the set twice.
  local slots = expectedSlots or M.standardSlots(enaField, adjField)
  local empty, differ, list = 0, 0, {}
  for i = 1, #slots do
    local cell = slots[i]
    local held = tonumber(ids[cell.slot0 + 1]) or 0
    if held == 0 then
      empty = empty + 1
      list[#list + 1] = { slot0 = cell.slot0, id = cell.id, reason = "empty" }
    elseif held ~= cell.id then
      differ = differ + 1
      list[#list + 1] = { slot0 = cell.slot0, id = cell.id, held = held, reason = "function" }
    end
  end

  local total = #slots
  local verdict = "match"
  if total > 0 and empty == total then
    verdict = "empty"
  elseif (empty + differ) > 0 then
    verdict = "differ"
  end
  return {
    verdict = verdict,
    total = total,
    empty = empty,
    differ = differ,
    count = empty + differ,
    slots = list,
    -- The flag that keeps this verdict from being read as the one M.compareStep makes. A board whose
    -- every slot names the right function can still have every window wrong, and this comparison
    -- would call it a match.
    idsOnly = true
  }
end

return M
