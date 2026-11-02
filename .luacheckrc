std = "lua54"

-- The globals EdgeTX 2.12 publishes that this tree reads. Every name below is a row of a table
-- the firmware's global lookup searches (`_global_symbols` in radio/src/thirdparty/Lua/src/linit.c:
-- base_func, etxlib, etxdir, etxcst, etxstr, colorlib on colour radios) or of `rotables` in the same
-- file. A name EdgeTX does not publish is nil on the radio, so it is fixed where it is read rather
-- than declared here: declaring it would hide exactly the defect this list exists to show.
globals = {
  -- Scripting engine (etxlib)
  "loadScript",

  -- System, time, model (etxlib, rotables)
  "getTime",
  "getDateTime",
  "getRtcTime",
  "getUsage",
  "getAvailableMemory",
  "getCpuLoad",
  "model",
  "getVersion",
  "getFieldInfo",
  "getSwitchIndex",
  "getSourceIndex",
  "getGeneralSettings",
  "getTxGPS",
  "FUNC_PLAY_SCRIPT",

  -- Filesystem. These are bare globals of the firmware's filesystem library, not members of an
  -- os table -- this Lua has none -- so a guard written as os.remove can never pass and the
  -- name has to be spelled the way the radio publishes it.
  "fstat",
  "dir",
  "del",
  "rename",
  "mkdir",

  -- Shared memory between Lua states
  "setShmVar",
  "getShmVar",

  -- Telemetry, sensors, serial (etxlib)
  "getValue",
  "getRSSI",
  "setTelemetryValue",
  "crossfireTelemetryPush",
  "crossfireTelemetryPop",
  "serialWrite",

  -- Audio and haptics (etxlib)
  "playFile",
  "playNumber",
  "playHaptic",

  -- Display/LCD
  "lcd",
  "lvgl",
  "Bitmap",
  "LCD_W",
  "LCD_H",

  -- Colors (colorlib)
  "WHITE",
  "BLACK",
  "RED",
  "GREEN",
  "YELLOW",
  "BLUE",
  "MAGENTA",
  "CYAN",
  "ORANGE",
  "DARKGREY",
  "COLOR_THEME_PRIMARY1",
  "COLOR_THEME_PRIMARY2",
  "COLOR_THEME_PRIMARY3",
  "COLOR_THEME_SECONDARY1",
  "COLOR_THEME_SECONDARY2",
  "COLOR_THEME_SECONDARY3",
  "COLOR_THEME_WARNING",
  "COLOR_THEME_DISABLED",
  "COLOR_THEME_FOCUS",
  "COLOR_THEME_ACTIVE",
  "COLOR_THEME_EDIT",

  -- Font sizes and number flags (etxcst)
  "DBLSIZE",
  "MIDSIZE",
  "SMLSIZE",
  "TINSIZE",
  "BOLD",
  "XXLSIZE",
  "PREC1",
  "PREC2",

  -- Alignment (etxcst)
  "CENTER",
  "VCENTER",
  "LEFT",
  "RIGHT",

  -- Telemetry units (etxcst)
  "UNIT_RAW",
  "UNIT_VOLTS",
  "UNIT_AMPS",
  "UNIT_PERCENT",
  "UNIT_CELSIUS",
  "UNIT_FAHRENHEIT",
  "UNIT_MAH",
  "UNIT_RPMS",
  "UNIT_DEGREE",
  "UNIT_G",
  "UNIT_METERS",
  "UNIT_METERS_PER_SECOND",
  "UNIT_GPS",
  "UNIT_CELLS",

  -- Key events every target publishes (radio/util/hw_defs/lua_keys.jinja, outside every
  -- conditional). The rest of the EVT_* family depends on the radio's keys and is read as
  -- _G.<name> where it is optional.
  "EVT_VIRTUAL_ENTER",
  "EVT_VIRTUAL_EXIT",
  "EVT_EXIT_BREAK",

  -- Bit operations
  "bit32",

  -- Not EdgeTX. `system` is the Ethos API and `Rf2Runtime` is set by nothing in this tree; both
  -- are read only behind a type guard, so on EdgeTX the guarded branch never runs. Listed so the
  -- check stays about names that are actually missing, not about these guards.
  "system",
  "Rf2Runtime",

  -- Global state of the suite
  "rfsuite",
  "_G",
}

-- Dashboard objects hand their value closures to lvgl.build, and the firmware's reactive
-- sweep then runs them per frame on the refresh's leftover budget, outside any pcall -- so
-- they read the precomputed `state.derived` snapshot and never probe. A probe re-introduced
-- into an object fails here instead of waiting for a reviewer's eye. `common.lua` is
-- exempt: it defines mapTelemetrySource, which widgets/dashboard/derived.lua calls from
-- the widget pass, where probing is legal.
local probe_globals = {
  ["model"] = true, ["getValue"] = true, ["getFieldInfo"] = true,
  -- Reading the card is a probe like any other: derived.lua stats /IMAGES/ for the model
  -- picture, and an object doing the same would do it once per frame.
  ["fstat"] = true, ["dir"] = true,
  -- And writing to it is worse than reading it, so the three that do are subtracted here too.
  -- Without this, naming them above would have quietly widened what an object may do.
  ["del"] = true, ["rename"] = true, ["mkdir"] = true,
  -- The rest of the firmware's functions named above: telemetry and link reads, clocks, memory,
  -- the serial and CRSF transports, audio and the bitmap loader. None of them was declared before,
  -- so no object could call one without a warning; subtracting them keeps it that way.
  ["getRSSI"] = true, ["getTxGPS"] = true, ["getSourceIndex"] = true,
  ["getDateTime"] = true, ["getRtcTime"] = true, ["getAvailableMemory"] = true, ["getCpuLoad"] = true,
  ["crossfireTelemetryPush"] = true, ["crossfireTelemetryPop"] = true, ["serialWrite"] = true,
  ["playFile"] = true, ["playNumber"] = true, ["playHaptic"] = true, ["Bitmap"] = true,
}
local object_globals = {}
for _, g in ipairs(globals) do
  if not probe_globals[g] then
    object_globals[#object_globals + 1] = g
  end
end
-- `new_globals` rather than `globals`: a per-path `globals` is MERGED with the one above it,
-- so a shortened list handed to a path adds nothing and takes nothing away. `new_globals`
-- replaces, which is what a restriction has to do.
files["src/rfsuite/widgets/dashboard/objects"] = { new_globals = object_globals }
files["src/rfsuite/widgets/dashboard/objects/common.lua"] = { new_globals = globals }
-- The in-flight tuning surface hands lvgl.build the same kind of value closures and is under the
-- same rule for the same reason: they run per frame in the reactive sweep, on the leftover budget,
-- outside the pcall. It reads the snapshot its own drive publishes and probes nothing.
--
-- The same set of names as the objects rule above, and it names them directly because there is
-- one file rather than a directory: `not_globals` subtracts from the inherited list, which is
-- what a single-file restriction needs, and `new_globals` would have to repeat the whole list
-- to take these names out of it. Verified in both directions -- a planted `model` read in this
-- file reports "accessing undefined variable 'model'", and removing the entry silences it.
files["src/rfsuite/widgets/dashboard/inflight/screen.lua"] = {
  not_globals = { "model", "getValue", "getFieldInfo", "fstat", "dir",
                  "del", "rename", "mkdir",
                  "getRSSI", "getTxGPS", "getSourceIndex",
                  "getDateTime", "getRtcTime", "getAvailableMemory", "getCpuLoad",
                  "crossfireTelemetryPush", "crossfireTelemetryPop", "serialWrite",
                  "playFile", "playNumber", "playHaptic", "Bitmap" }
}

-- Code style rules
max_line_length = 140
max_code_line_length = 140

-- Allow unused arguments in functions (common in callbacks)
unused_args = false
unused_secondaries = false
