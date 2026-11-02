---
title: Audio Events
sidebar_label: Events
sidebar_position: 10
---

# Audio Events

The suite provides spoken voice alerts and tone callouts for flight telemetry, battery status, system state, and flight controller notifications. Audio events are configured under:

*System* → *Settings* → *Audio* → *Events*

The ten category pages share a common configuration table (`preferences.audio_events`), stored with the radio in `/SCRIPTS/TOOLS/rfsuite.user/preferences.lua` with model-specific overrides (such as the ESC temperature levels) in each flight controller's own file beside it. See [Configuration files](../reference/configuration-files.md).

A save that cannot be stored reports *Save failed* with the reason: *the settings file could not be written to the SD card* where the card refused a file, and *model settings store not available* where the part of the suite that writes the model's own file could not be loaded.

---

## Categories & Settings

Every row on these pages has a `?` button beside its control, which opens a short explanation of that row. The `?` in the page header says what the page is for.

### 1. On Connect

What is said once when a model connects. On a quick connect the model's name and the pack check come on the first pass after the connection (the dashboard starts its announcements once the battery configuration has been read from the flight controller), the battery capacity one pass later, and the SmartFuel level last; on a slow connect the battery capacity can come before the pack check. The rows are listed in the quick-connect order.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Model Name | `model_announcement` | Off | Radio | Plays the sound file named after the model, `/SOUNDS/<name>.wav` (a name with spaces is also looked up with underscores), once when the model connects. The name is the craft name read from the flight controller when it is already known, otherwise the radio's model name. Nothing is said when the card has no such file. |
| Pack Not Full | `pack_not_full` | Off | Radio | Once when the model connects: a warning when the pack's voltage per cell is below the flight controller's *Full cell voltage* (*Setup* → *Power* → *Battery*; on firmware with cell voltages per battery profile, the active profile's) less the margin below. The voltage is spoken as set under *Voltage* → *Announce as*: the pack voltage by default, or the voltage per cell. Judged once per connection and then latched. The verdict is taken whether or not this announcement is on, and a dashboard theme can draw it -- Urban colours its fuel gauge orange instead of green for a pack that was not full. |
| Margin (mV/cell) | `pack_not_full_margin` | 0 mV | Radio | How far below *Full cell voltage* a cell may be and still count as full (0 to 500 mV per cell). At 0 a pack counts as full from *Full cell voltage* up, which is the flight controller's own rule for its "battery not full" warning. A settings file saved before this default changed keeps the margin it holds (100 mV until then). It applies to the verdict a dashboard theme draws as well; the row can be edited only while *Pack Not Full* is on, and the value set there stays in force when it is switched off. |
| Battery Capacity | `battery_profile` | On | Radio | Speaks the capacity of the active battery profile in mAh (e.g. "Battery 5000 mAh") when the model connects and whenever the battery profile changes; the profile number when that profile has no capacity set. Needs the Battery Profile sensor (97) or System Config (121); without either, nothing is spoken on connect. |
| SmartFuel | `initial_fuel` | On | Radio | Speaks the remaining SmartFuel percentage (e.g. "Battery 95%") once after the model connects. Independent of the *SmartFuel* switch on the SmartFuel page, which governs the descending callouts and the empty alarm. |

#### When the SmartFuel Level Is Spoken
To prevent spurious "Battery 0%" announcements at startup:
- **Telemetry Guard (`fuelTelemetrySeen`):** The announcement is held until valid fuel telemetry has been delivered by the flight controller or SmartFuel.
- **Dynamic Deferral Window:** When the model connects, the announcement is deferred for a window derived from the model's SmartFuel stabilization delay (`stabilize_delay`, defaulting to at least 8.0 seconds).
- **Carried-Over Reading Detection:** EdgeTX retains the last received sensor reading across disconnections. If a new connection reports a reading bit-identical to the previous session's disconnect value (`previousSessionFuel`), it is treated as a carried-over reading and held until the new pack's fresh reading arrives.
- **Immediate vs. Timed Callout:** As soon as a positive, fresh reading arrives (`fuel > 0` and different from the previous pack), the percentage is spoken immediately. If no positive reading has arrived by the end of the window, the reading at that moment is spoken, so a SmartFuel value that has not come up yet is announced as 0%.

A sound pack without the announcement's file (`evt/battery.wav` for an electric model, `stat/alerts/fuel.wav` for nitro) has nothing to play. Once the choice between the two files can no longer change (the model type is set explicitly, the battery configuration has been read from the flight controller, or the pack carries neither file), the announcement counts as made for that connection: nothing is spoken and one warning in the log says which file is missing. Until then it is tried again on every pass, because a model whose type is not yet known may still turn out to need the file the pack does carry.

### 2. Arming

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Arming flags | `arming_flags` | On | Radio | Announces arming ("Armed") and disarming ("Disarmed"). |

### 3. Governor

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Governor state | `governor_state` | On | Radio | Spoken announcements when the governor transitions between operating states (Idle, Spool-up, Recovery, Active, Throttle off, Lost headspeed, Autorotation, Bailout, Bypass). A state is spoken once it has held for a moment. Individual states can be toggled independently. |

### 4. Voltage

Monitors the main pack voltage and the model's power supply.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Voltage alert | `voltage_alert` | On | Radio | Voice alert when the pack voltage drops below the warning threshold, the flight controller's warning cell voltage times the cell count. The voltage the alert fired at is spoken with it, as set under *Announce as*. Without a cell count -- the flight controller set to detect it and no pack detected yet -- there is no threshold and the alert stays silent. A pack voltage below half a cell never sets a count, but a count already held for a pack that was detected is kept, so the alert keeps that pack's threshold when the pack is pulled or collapses. |
| Raise Volume | `voltage_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The alert's critical level -- the pack held below the flight controller's minimum cell voltage times the cell count for *Hold* -- is spoken at the *Alert Level*, until the alert clears; before it is reached, the warning is spoken at the normal level. |
| Hold | `voltage_hold` | 2 s | Radio | How long the reading has to stay below the warning threshold before the alert speaks (0 to 10 s). A hold of 0 announces on the first reading below the level, which is the behaviour before this setting existed. |
| Reset (mV/cell) | `voltage_reset` | 100 mV | Radio | How far above the warning threshold the pack has to come back, in millivolts per cell, before the alert counts as cleared (50 to 500 mV per cell, in steps of 50). Editable while *Voltage alert* is on. |
| Main power lost | `main_power_lost` | Off | Radio | Announces that the main pack has gone while the flight controller is still alive on a BEC or a backup battery, with the BEC voltage spoken. The pack coming back is announced once, with its voltage; if that falls into the quarter of a second after another announcement's file, it is made on the next pass. |
| Raise Volume | `main_power_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. *Main power lost* is spoken at the *Alert Level*; the pack coming back does not raise it. |
| Announce as | `voltage_announce` | Pack | Radio | How a flight pack voltage is spoken: *Pack* says the pack voltage with one decimal, *Cell* the voltage per cell with two. It applies to the voltage alert, to the pack coming back after *Main power lost*, and to *Pack Not Full* on the *On Connect* page. The BEC voltage spoken with *Main power lost*, and the BEC / receiver alerts of *Setup* → *Power* → *Alerts*, are not flight pack readings and are spoken as they are. Where no cell count is known, the pack voltage is spoken. |
| Repeat | `voltage_repeat` | Until cleared | Radio | How often an alert on this page speaks while its condition holds -- see *Repeat and Haptic* below. |
| Haptic | `voltage_haptic` | On | Radio | Transmitter vibration alongside the voltage, main power and BEC / receiver alerts. |
| Raise Volume BEC/RX | `bec_rx_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The BEC / receiver alert set up under *Setup* → *Power* → *Alerts* is spoken at the *Alert Level*. One switch for both, since only one of them is on at a time. |

#### Sag Under Load, and a Pack That Is Genuinely Gone
- **Warning threshold:** it is not set on this page. It is the flight controller's own `vbatwarningcellvoltage` times the cell count, so the alert and the flight controller judge the same pack.
- **Hold (`voltage_hold`):** a hard collective pull drags the reading under that line for a moment, and a pack that sags is not a pack that is down. The alert waits for the hold time, then repeats every 10 seconds while the voltage stays low.
- **Reset (`voltage_reset`):** the alert counts as cleared -- which starts a fresh *Repeat* count, as the step into the critical level below also does -- only once the pack is back above the warning threshold plus this margin per cell. The margin is per cell because the threshold is: 100 mV per cell is 0.3 V on a 3S pack and 1.2 V on 12S. Before this setting the margin was a fixed 0.5 V for any pack, which is 0.17 V per cell on 3S but 0.04 V on 12S, so on a 12S pack the recovery after a sag could end the episode and a *Repeat* of *Once* speak again at every sag. Announcements stay at least 10 seconds apart either way, except the step into the critical level below, which is spoken at once.
- **Announce as (`voltage_announce`):** the voltage per cell reads the same on every pack, so a pilot who flies several pack sizes hears one number to judge. It is the pack voltage divided by the cell count the warning threshold uses -- the flight controller's configured cell count, or the detected one where the configuration says auto -- not a separate sensor.
- **The critical level (`vbatmincellvoltage`):** the flight controller's minimum cell voltage times the cell count, the level its own Battery page calls the alarm. Once the pack has also stayed under that line for *Hold*, the alert enters its critical level the way the temperature and link quality alerts do: the same announcement is made at once, even within 10 seconds of the warning's, and the *Repeat* count starts again, so a *Repeat* of *Once* says it a second time. The critical level stays until the alert clears (the pack back above the warning threshold plus *Reset*), so a pack recovering for a moment between two pulls does not announce it anew. Only the critical level raises the master volume (*Raise Volume* above). Where the board sends no minimum, 3.30 V per cell is taken, that page's default; a minimum above the warning threshold is taken as the warning threshold.
- **Main Power Lost (`main_power_lost`):** for a setup with a backup guard or a separate receiver battery. It needs the pack to have read a real voltage since the connection began, to read as gone rather than merely low, and a BEC voltage beside it -- without one there is nothing left to say anything is still powered. It repeats every 10 seconds while the pack stays away, and announces once more, with the pack voltage as set under *Announce as*, when the pack comes back. Those three tests are also what the dashboard publishes as `state.mainPowerLost` for a theme to draw ([dashboard themes](../developer/dashboard-themes.md)) -- one definition, so a screen and the announcement cannot disagree. The switch on this page governs the announcement alone; a theme drawing the condition does so whether or not anything is spoken.

### 5. Profiles

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| PID profile | `pid_profile` | On | Radio | Announces the PID profile index when switched (e.g. "Profile 1"). |
| Rate profile | `rate_profile` | On | Radio | Announces the rate profile index when switched (e.g. "Rate 1"). |

### 6. ESC & MCU Temperature

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| ESC temperature | `esc_temperature` | Off | Radio | Speaks the ESC temperature when it reaches the warning or the critical level. |
| Raise Volume | `esc_temperature_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The ESC temperature alert's critical level is spoken at the *Alert Level*. |
| ESC warning | `esc_threshold` | 90 °C | Model | The lower ESC level (60 to 300 °C). Configured per model. |
| ESC critical | `esc_critical` | 110 °C | Model | The upper ESC level (60 to 300 °C). Configured per model. |
| MCU temperature | `mcu_temperature` | Off | Radio | Speaks the flight controller's MCU temperature when it reaches the warning or the critical level. |
| Raise Volume | `mcu_temperature_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The MCU temperature alert's critical level is spoken at the *Alert Level*. |
| MCU warning | `mcu_threshold` | 80 °C | Radio | The lower MCU level (40 to 150 °C). Global radio setting. |
| MCU critical | `mcu_critical` | 95 °C | Radio | The upper MCU level (40 to 150 °C). Global radio setting. |
| ESC Load | `esc_load` | Off | Radio | Speaks "ESC Load" and the load in percent when it reaches the warning or critical level below, while the model is armed. Silent without an ESC current limit -- see *ESC load* below. |
| Raise Volume | `esc_load_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The ESC load alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `esc_load_warn` | 80 % | Radio | The lower load level (10 to 200 %, in steps of 5). Spoken without vibration. |
| Critical (%) | `esc_load_critical` | 100 % | Radio | The upper load level (10 to 200 %, in steps of 5). Vibrates as well when *Haptic* is on. |
| Hold (s) | `esc_load_hold` | 5 s | Radio | How long the load has to stay at or above a level before it is spoken (0 to 30 s). |
| Repeat | `esc_repeat` | Until cleared | Radio | How often either temperature alert or the ESC load alert speaks while it holds -- see *Repeat and Haptic* below. |
| Haptic | `esc_haptic` | On | Radio | Transmitter vibration alongside the ESC and MCU temperature alerts at their **critical** level, and at the critical ESC load level. |

Each alert has two levels and says the same words at both, followed by the temperature: *ESC
temperature warning* or *MCU temperature*, then the reading. It works like the link quality alert:

- **A rise into a level is spoken at once**, also when the alert spoke a moment before at the
  level below, and the level it has entered starts its own repeat count.
- **Falling back is not spoken.** A level is left only once the reading is more than 5 °C below it, so a
  sensor resting on a level does not announce every rise. A fall from the critical to the warning
  level starts the warning level's own repeat count, so with *Repeat* set to a count the warning
  level speaks again (its own announcement, not a recovery), 10 s after the last one.
- **Only the critical level vibrates**, and only while *Haptic* is on. The warning level speaks
  without vibration.
- **Only the critical level raises the master volume** set up under [Volume](../pages/settings/audio/volume.md)
  to its *Alert Level*: each announcement of it, while the alert's *Raise Volume* is on -- see
  *Raise Volume* below. The warning level is spoken at the normal level.
- **A critical level set below the warning level** is taken as the warning level: both are then
  crossed together, and the alert speaks at the critical level.

The defaults put the MCU's critical level at 95 °C. The reading is the temperature of the chip
itself, and the chips flight controllers are built on are rated for 105 °C or more at the
junction in their commercial grades (STM32F4, F7 and G4 at 105 °C, STM32H7 at 125 °C), so 95 °C
leaves a margin below the lowest of those ratings. The ESC's levels are a property of the ESC:
set them to what its maker gives as its temperature limit.

A settings file written before the critical levels existed keeps its warning levels; the critical
levels start at their defaults. A warning level stored above 110 °C (ESC) or 95 °C (MCU) is then
above the critical default, and the alert speaks at the critical level from that warning level on
until a critical level is set.

All four levels are stored and compared in °C, the unit the flight controller reports. On a radio
set to Fahrenheit under [Localization](../pages/settings/localization.md) the page shows them in
°F -- each step is still one degree Celsius, so they move in steps of about 2 °F -- and both
alerts speak the temperature in °F.

The ESC levels are stored with the model while a flight controller is connected -- the rows then
read *Warning [Model]* and *Critical [Model]* -- and are otherwise the radio-wide defaults that every
model without a value of its own reads. Each level is taken from the model where the model has one
and from the radio where it has not. The MCU levels are always radio-wide.

When the model's file cannot be written, *Save* reports the failure and the model goes on with the
levels it had before. The page still shows the number that was entered, so saving again writes
it once the file can be written.

#### ESC load

The ESC load is the current as a percentage of the limit the speed controller is set to allow,
the *ESC Current Limit* under *Setup* → *Power* → *Preferences* ([Power Preferences](../pages/setup/power/preferences.md)).
An AM32, Scorpion or YGE controller fills that limit in when its settings page is opened; for any
other it is typed in there by hand. **Without a limit on file the alert is silent**, whatever the
current. A load above 100 % is the controller being asked for more than its limit, which is why
the levels reach 200 %.

- **Armed only.** A load on the bench is not announced.
- **A level is entered once the load has stayed at or above it for the hold**, so a punch-out that
  is over within a few seconds stays quiet. A level that has been entered is spoken at once,
  followed by the load in percent; reaching the critical level from the warning one is spoken at
  once as well, after its own hold.
- **Leaving a level costs 5 percentage points** below its line, so a load riding on a line does
  not announce every time it climbs back over it. Recovering is not announced: a load that falls
  from critical back to the warning level is spoken again only when the warning level's next
  *Repeat* is due, and a load that falls below both levels is not spoken at all.
- **Only the critical level vibrates**, and only while *Haptic* is on -- the rule the link
  quality alert follows.
- **Radio-wide**, unlike the ESC temperature threshold: the load is already a share of the
  model's own limit, so one pair of percentages means the same in every model.
- The load is computed the same way whether the dashboard widget or the RFSuite tool is running --
  this pass's current over the limit stored for the model -- so the alert speaks from either.
- Its critical level raises the master volume as the temperature alerts' does -- see *Raise Volume* below.

### 7. Adjustments

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Adjustment events | `adjustment_events` | Off | Radio | Audio feedback when adjusting tuning parameters via in-flight switches or rotary knobs. |

#### What an Adjustment Announcement Says
The new value, preceded by the name of the adjustment function whenever the pilot moves on to a different function than the last one adjusted, and on the first adjustment after a connect (when the [background decoder](../reference/background-decoder.md) makes the announcements, only after the first connect since the model was loaded). The name is one recording per function, `inflight/fn/<id>.wav`, worded as the Rotorflight Configurator names the function in that language (for example *Pitch RC Expo*, *Governor Idle Throttle*); a function id without a recording falls back to the words in `adj/`. Every adjustment function the firmware defines is named this way except the four profile switches (rate, PID, LED and OSD profile) and the battery profile, which the adjustment announcement does not speak at all. A rate or PID profile change is announced under *Profiles* and a battery profile change under *On Connect* (*Battery Capacity*), so announcing them here as well would say the same event twice; with those announcements switched off, such an adjustment is not spoken.

The flight controller reports an adjustment for three seconds after it was made, and nothing tells how long ago that was. So an adjustment still being reported when the announcements start is not announced: this happens when the configuration tool is opened, when the background decoder starts or the dashboard takes over from it -- where the part that stood before has usually announced it already -- and for an adjustment made while the suite is still connecting.

The grouped tuning overlay shares this radio-wide switch and the critical-alarm quiet period;
per-model `audio_events` entries do not override `adjustment_events`. On its ground surface,
an off hint and **Turn on announcements** button offer an explicit save of the global preference.
Opening the surface does not change it; a failed save leaves it off and shows a warning. The
hint and button are absent while armed, and the default remains off. The overlay uses
`inflight/selected.wav` before the selected function name and known value. Profile changes use the general PID/rate announcement when enabled; otherwise the in-flight overlay
announces `evt/profile.wav` plus the active number. In flight, unread/unknown profiles use
`inflight/paused.wav`; returning to read profiles uses `inflight/resumed.wav` without an
interlock cycle. Both cues are silent on the ground. Group selection
speaks the group title from `inflight/group/<group>.wav`, and a function its name from
`inflight/fn/<id>.wav`, the same recording the adjustment announcement uses. Browse names settle for 700 ms, with newer requests
replacing earlier ones. Files resolve below `SOUNDS/rf/<locale>/` in both EN and DE packages.

### 8. SmartFuel

Callouts of the SmartFuel level while the model is connected. The flight controller computes the value when SmartFuel is switched on there (*Setup* → *Power* → *SmartFuel*, MSP API 12.0.9 and later); otherwise the radio computes it from the local source chosen under *Setup* → *Power* → *Preferences*.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| SmartFuel | `fuel_alerts` | On | Radio | Master switch for the descending percentage callouts and the empty alarm. |
| Callout % | `fuel_callout_percent` | Every 10% | Radio | The steps at which the falling level is spoken, each once: *Only at 10%*, or every 5%, 10%, 20%, 25% or 50%. |
| Finer below | `fuel_finer_below` | Off | Radio | The level from which the steps become finer: *Off*, or 10%, 15%, 20%, 25%, 30%, 40% or 50% -- see *Finer Steps Near the End* below. |
| Finer step | `fuel_finer_step` | Every 5% | Radio | The step below *Finer below*: every 1%, 2% or 5%. Editable while *Finer below* is not *Off*. |
| Repeat | `fuel_repeat_below_zero` | Once | Radio | How often the empty battery / fuel alarm speaks while fuel is at 0% -- *Until cleared*, or 1 to 10 announcements ten seconds apart. The descending percentage callouts are not repeated: each step is spoken once as it is passed. |
| Haptic | `fuel_haptic_below_zero` | Off | Radio | Transmitter vibration alongside the empty alarm. |
| Raise Volume | `fuel_empty_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The empty alarm at 0% is spoken at the *Alert Level*; the percentage callouts above it do not raise it. |

#### Finer Steps Near the End
With *Finer below* set, the callout speaks the *Callout %* steps above that level, then the level itself, then every multiple of *Finer step* below it down to the step. *Every 20%* with finer steps of 5% below 30% speaks 80, 60, 40, 30, 25, 20, 15, 10 and 5%; with 2% below 25% the finer part is 25, 24, 22 and so on down to 2%. The *Callout %* steps below the level are not spoken on their own. With *Finer below* at *Off* the steps are the *Callout %* steps alone, as before the setting existed.

A step is passed once its announcement was handed to the radio, or once the sound pack turned out to have no file for it. An announcement that falls into the quarter of a second after the previous file -- another alert spoken in the same pass -- is made on the next pass rather than lost, and when the level has fallen past further steps meanwhile, the lowest one passed is spoken.

### 9. Link Quality

Alerts about the radio link and the flight controller's telemetry.

The warning and critical levels set here also colour the dashboard: the Urban theme's link bars
turn amber and red at them, and the Default theme's link quality box does where its *Colour at
alert levels* setting is on. A theme reads every alert's levels from one place, `state.alerts`
([dashboard themes](../developer/dashboard-themes.md)), so a screen and the voice agree; saving
this page reloads the dashboard.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Link Quality | `lq_alert` | Off | Radio | Spoken warning when RC link quality drops below defined levels. A receiver that reports no link quality stays silent: the value that arrives in its place is a signal strength in dBm, not a percentage. |
| Raise Volume | `lq_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The link quality alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `lq_warn` | 70% | Radio | First warning threshold (1 to 100%). |
| Critical (%) | `lq_critical` | 50% | Radio | Critical link alarm threshold (1 to 100%). |
| Telemetry Lost | `telemetry_lost` | Off | Radio | Announces a flight controller that stops sending telemetry while the model is armed and the radio link is up, and announces it again when its telemetry is back. |
| Raise Volume | `telemetry_lost_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The lost telemetry announcement is spoken at the *Alert Level*; its return does not raise it. |
| Telemetry Dropouts | `dropouts_alert` | Off | Radio | Speaks "Telemetry Dropouts" while the model is armed and the flight controller's telemetry frames go missing too often -- see *Telemetry Dropouts* below. |
| Raise Volume | `dropouts_raise` | Off | Radio | *Master volume* mode only -- see *Raise Volume* below. The dropouts alert, which has one level, is spoken at the *Alert Level*. Off by default: a stuttering telemetry stream is not a danger in itself. |
| Dropouts | `dropouts_count` | 3 | Radio | How many gaps in the telemetry frames within the window set the alert off (1 to 50). |
| Window (s) | `dropouts_window` | 10 s | Radio | The time the gaps are counted over (4 to 60 seconds). |
| TX Power | `tpwr_alert` | Off | Radio | While armed, speaks the transmitter's power as a percentage of its maximum when it climbs to the warning or critical level. Speaks only where the ExpressLRS module reports dynamic power on -- see *TX Power* below. |
| Raise Volume | `tpwr_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The TX power alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `tpwr_warn` | 60% | Radio | The lower TX power level (1 to 100% of the maximum). Spoken without vibration. |
| Critical (%) | `tpwr_critical` | 85% | Radio | The upper TX power level (1 to 100% of the maximum). A critical level entered below the warning level is taken as the warning level. |
| Hold (s) | `tpwr_hold` | 2 s | Radio | How long the power has to stay at or above a level before it is spoken (0 to 10 s; 0 speaks at once). |
| Own Maximum | `tpwr_limit` | Off | Radio | Takes *Maximum (mW)* below as 100% instead of the Max Power read from the module. |
| Maximum (mW) | `tpwr_max` | 100 mW | Radio | The power taken as 100% while *Own Maximum* is on: 25, 50, 100, 250, 500, 1000 or 2000 mW. |
| RSSI | `rssi_alert` | Off | Radio | While the model is armed, speaks "RSSI" and the receiver's signal headroom in percent when it falls to the warning or critical level -- see *RSSI and Downlink Headroom* below. |
| Raise Volume | `rssi_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The RSSI alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `rssi_warn` | 15% | Radio | The upper level of the RSSI alert (1 to 100%). |
| Critical (%) | `rssi_critical` | 8% | Radio | The lower level of the RSSI alert (1 to 100%). |
| Hold (s) | `rssi_hold` | 2 s | Radio | How long the headroom has to stay at or below a level before the RSSI alert speaks it (0 to 10 seconds). |
| Downlink | `trss_alert` | Off | Radio | The same for the signal at the transmitter module (`TRSS`): speaks "Downlink" and its headroom. |
| Raise Volume | `trss_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The Downlink alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `trss_warn` | 15% | Radio | The upper level of the Downlink alert (1 to 100%). |
| Critical (%) | `trss_critical` | 8% | Radio | The lower level of the Downlink alert (1 to 100%). |
| Hold (s) | `trss_hold` | 2 s | Radio | How long the headroom has to stay at or below a level before the Downlink alert speaks it (0 to 10 seconds). |
| SNR | `rsnr_alert` | Off | Radio | While the model is armed, speaks "SNR" and where the receiver's signal-to-noise ratio sits between the air rate's two dynamic-power thresholds, in percent, when it falls to the warning or critical level -- see *SNR and Downlink SNR* below. |
| Raise Volume | `rsnr_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The SNR alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `rsnr_warn` | 30% | Radio | The upper level of the SNR alert (0 to 100%). |
| Critical (%) | `rsnr_critical` | 0% | Radio | The lower level of the SNR alert (0 to 100%); 0% is the threshold at which ExpressLRS asks for more power. |
| Hold (s) | `rsnr_hold` | 2 s | Radio | How long the SNR has to stay at or below a level before the SNR alert speaks it (0 to 10 seconds). |
| Downlink SNR | `tsnr_alert` | Off | Radio | The same for the signal-to-noise ratio at the transmitter module (`TSNR`): speaks "Downlink SNR" and its percentage. |
| Raise Volume | `tsnr_raise` | On | Radio | *Master volume* mode only -- see *Raise Volume* below. The Downlink SNR alert's critical level is spoken at the *Alert Level*. |
| Warning (%) | `tsnr_warn` | 30% | Radio | The upper level of the Downlink SNR alert (0 to 100%). |
| Critical (%) | `tsnr_critical` | 0% | Radio | The lower level of the Downlink SNR alert (0 to 100%). |
| Hold (s) | `tsnr_hold` | 2 s | Radio | How long the SNR has to stay at or below a level before the Downlink SNR alert speaks it (0 to 10 seconds). |
| Repeat | `link_repeat` | Until cleared | Radio | How often the link quality, RSSI, Downlink, both SNR, dropouts and TX power alerts speak while their condition holds -- see *Repeat and Haptic* below. |
| Haptic | `link_haptic` | On | Radio | Transmitter vibration alongside the link quality, RSSI, Downlink, both SNR and TX power alerts at their **critical** level, and alongside the lost telemetry announcement. Never alongside the dropouts alert. |

#### TX Power
The transmitter module's power (the `TPWR` reading, in mW) is judged as a share of the most the module may send with. That maximum and whether dynamic power is on are not on any telemetry frame, so the suite asks the module for them over the CRSF parameter protocol: the ExpressLRS fields *Max Power* and *Dynamic* in its *TX Power* folder, the same ones the module's own Lua script shows. Both are shown read-only on *Tools* → *Diagnostics* → *ELRS Link*.

- **Only with dynamic power.** With fixed power the module sends at its maximum all the time, so the share says nothing about the link and the alert stays silent. Any *Dynamic* choice other than *Off* counts as on, including the AUX choices, which add a switch that boosts the module to its maximum -- the alert then speaks at the critical level, because the power is at its maximum.
- **Silent where the maximum is not known**: a module that is not ExpressLRS or does not answer, and a dual-band module built for the CE domain, whose *Max Power* labels are pairs (one limit per band) and do not say which applies. *Own Maximum* gives the alert a maximum there, but not dynamic power: it too speaks only where the module has said dynamic power is on.
- **When the module is asked.** Once per connection, after the connect sequence, only while the alert is on and the model is disarmed, one frame per announcement pass. Every frame sent to the module goes out in place of one RC channels frame, which is why nothing is sent while armed. The read is shared with the standby screen and the ELRS link page and takes four fields (Packet Rate, Telemetry Ratio, Max Power and Dynamic). The first time a module is seen, its parameter list is walked by name up to the last of them; their positions are then kept for that module while the alert is on or a standby screen is shown, and every later connection asks for those fields directly (the discovery ping and one frame per field). A change made in the module's settings is seen at the next connection. A link that drops and comes back while the model is still armed keeps the last connection's answer, since nothing may be sent to ask again before the disarm. A model armed before a new connection's read has finished stays silent until the next disarm. A module that does not answer is given up after four discovery pings, and a read after 48 tries to send a frame, every try counted (a repeat, and one the radio's full output buffer refused); the alert then stays silent for that connection. The limit counts tries, not seconds, because a radio that runs its announcement passes slowly sends one frame per pass and still has to finish the read. A read an arming cuts short starts again after the disarm with a fresh count.
- **In the tool**, while *ELRS Link* is reading the module itself, the alert waits and reads afterwards: the two would otherwise take each other's answers.
- **Levels** as the link quality alert: a level entered is spoken at once with the percentage, recovering is silent, a level is left only 5 points below its line, and only the critical level vibrates. The power moves in the module's steps (for example 100 and 250 mW against a 250 mW maximum, 40% and 100%), so a module that steps down and back up again starts a new announcement each time it climbs back for longer than the hold.

#### What Telemetry Lost Covers, and What It Leaves to the Radio
Only a flight controller that stops sending while the radio link is still up is announced: the link statistics keep arriving and the radio stays connected, but the flight controller's telemetry frames have stayed away for 6 seconds. The radio cannot tell this case apart on its own until it reports each sensor as lost, 20 seconds later. A lost RF link is what the radio itself announces, and hearing the same event twice is worse than hearing it once, so a lost link stays silent here -- also when the flight controller's frames stopped with it. A drop while the model is disarmed is a normal power-off and stays silent too. The silence counts only after a telemetry frame has arrived since the suite's first audio pass of the current connection, so a flight controller that has sent none since then -- for example one that was already silent when the link returned -- is not announced.

The loss is announced **once**. A model that stays silent keeps the announcement's recovery window open, and it is the return that speaks again -- not the silence, however long it lasts.

#### RSSI and Downlink Headroom
A signal strength in dBm means little without the rate the link runs at: ExpressLRS specifies, for every air rate, the weakest signal its receiver still decodes -- the rate's *sensitivity floor* -- and a faster rate has a higher floor. So both alerts speak the **headroom** above that floor rather than the dBm figure: 0% is the floor, 100% is -40 dBm or stronger, in whole percent, the scale the Urban theme's link bars draw. On a 500 Hz LoRa rate on ExpressLRS 4.x (floor -105 dBm) the default warning level of 15% is about -95 dBm, the critical level of 8% about -100 dBm.

- **RSSI** is the signal at the receiver, the uplink, at the antenna the link statistics name as the one in use (`ANT`): `2RSS` while `ANT` names the second antenna, otherwise `1RSS` -- also on a link that reports no `ANT`. It is not the stronger of the two readings, because a receiver with one radio and an antenna switch updates only the antenna in use, so the other reading is the value it had when that antenna was last in use.
- **Downlink** is the signal at the transmitter module (`TRSS`), the telemetry coming back. Both directions run at one air rate, so both are measured against the one floor; the two alerts have their own switches and levels.
- **The floor comes from the module.** The `RFMD` value the link reports means a different rate on ExpressLRS 3.x and 4.x, so the suite asks the transmitter module once per connection which release it runs (one CRSF device ping). Until it has answered, with a module that is not ExpressLRS 3.x or 4.x, and on the two 3.x rates whose floor depends on the band (`50Hz` and `250Hz`), there is no floor and both alerts stay **silent** rather than guess one. The rates and floors are listed in `lib/link_rates.lua`.
- A level is spoken once the headroom has stayed at or below it for *Hold* -- the default 2 seconds lets a short antenna null with the rotor turning pass -- and a worsening is spoken at once. A level is left only once the headroom is 5 points above it again, so a reading resting on a level does not announce every time it dips under. Recovery is not spoken.
- Only while the model is armed. The device ping is sent as soon as an alert is on and the link is up, armed or not, so the floor is known by the time the model is armed.
- The critical level vibrates where the page's *Haptic* is on; the warning level never does, as with the link quality alert.
- Both alerts work under the dashboard widget and under the tool alike.

#### SNR and Downlink SNR
A signal-to-noise ratio in dB means little without the rate either: ExpressLRS's dynamic power asks for more power while the receiver's average SNR is at or below one threshold of the air rate and for less at or above a second one, and both differ per rate -- on 2.4 GHz LoRa 5 and 9.5 dB at 500 Hz, 3 and 9.5 dB at 250 Hz, 0 and 8.5 dB at 150 Hz, -1 and 6.5 dB at 50 Hz. So both alerts speak where the reading sits between the two: **0%** at or below the lower threshold, **100%** at or above the upper one, in whole percent. A fixed dB line would be wrong at both ends of the rate list.

- **SNR** is the receiver's figure (`RSNR`), **Downlink SNR** the transmitter module's (`TSNR`); each has its own switch and levels. ExpressLRS sets thresholds only for the receiver's SNR, so the downlink is measured on the same pair as a reference scale.
- **With dynamic power on, ExpressLRS holds the SNR inside this window on purpose**: it lowers the power whenever the SNR is above the upper threshold and raises it at the lower one, so a low figure is what it steers towards while the link is fine, and the transmit power is the better sign of a link running out. These alerts say most with a fixed transmit power. (ExpressLRS 4.x goes further and, once it has gathered enough readings, moves both thresholds to fit the link's own SNR spread; the alerts keep to the rate's configured figures, which are its starting point.)
- **On 900 MHz the window is narrow**: 1.5 to 3.5 dB between the two thresholds, while the link reports the SNR in whole dB. A single dB moves the figure by 29 to 67 points, so the warning and critical levels can be crossed in one step. ExpressLRS itself marks its 900 MHz figures for the LR1121 radio as still to be checked. With such a window the critical level can stay until the reading reaches the upper threshold.
- **Silent where there is no threshold**: on the FLRC and FSK rates, which report no usable SNR; on the three ExpressLRS 3.x rates whose thresholds depend on the band, which the link does not report (`50Hz`, `100Hz Full` and `250Hz`); and wherever the rate is not known, as for the headroom alerts above. The thresholds are listed per rate in `lib/link_rates.lua`.
- The rest is the shape of the headroom alerts: *Hold*, a worsening spoken at once, recovery silent, armed only, the critical level vibrating where *Haptic* is on, both call paths. A level is left only once the SNR is **more than one dB** above it again, counted on that rate's scale -- the smallest step the reading takes; on a level that sits on a whole dB, the second dB above it -- so an SNR flickering by one dB across a level does not announce at every flicker. The one exception is the top of the window: a reading at or above the upper threshold leaves every level set below 100%, since on a narrow window one dB above a high level would lie past the top and the level could never be left. Where a level sits on the step just below the top, a reading flickering between the two is therefore spoken at each dip with *Hold* 0; the default *Hold* of 2 seconds keeps a quick flicker quiet.

#### Telemetry Dropouts
Every frame of the flight controller's custom telemetry carries a frame number, and the suite counts each place where the numbers jump -- a gap of one or more frames that never arrived. It publishes that count itself as the sensor `*Skp`, at most every 2 seconds, from the moment the link comes up. The background function script, the dashboard and the tool each decode the frames while the others stand aside. When the decoding moves from one to another -- the tool opened or closed, the script pausing for a moment -- the count continues from the value the radio shows, and the first second of frames after the move is not counted, so a hand-over is not a gap. A lost link starts the count over at 0 where the dashboard or the tool that saw the loss decodes; the function script, and a tool opened after the loss, carry it on.

The count says that a flight *had* gaps. The alert asks whether the link is stuttering *now*: it compares the rise of the count within the last *Window* seconds against *Dropouts*. With the defaults, three gaps within ten seconds speak; two do not, and nor does a large total collected slowly over a long flight. The window starts at 4 seconds because the count only changes every 2.

- Only while the model is armed. Gaps on the ground before arming are not counted into the flight: the window starts with the first reading after arming.
- A count that starts over -- after a lost link -- is a new start, never an alert.
- The alert needs the `*Skp` sensor, that is the flight controller's custom CRSF telemetry decoded by the suite. Without it the alert stays silent.
- Spoken at once when the count is reached, then as often as *Repeat* says, ten seconds apart, while the rise stays at or above the count; nothing is spoken while it is below. It stays one alert until the rise has stayed below the count for a whole window, so a rate resting on the count -- falling below it and climbing back with the next gap -- neither starts a new alert nor a new repeat count. Recovery is not spoken.
- It never vibrates, whatever *Haptic* says: it has one level, and the link quality alert's lower level does not vibrate either.
- The gaps counted are those of the flight controller's telemetry on its way to the radio. A receiver that drops control frames on the way to the model is what *Link Quality* reports.

### 10. Rescue

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Rescue Active | `rescue_active` | Off | Radio | Speaks "Rescue -- Active" once when the flight controller's rescue starts. |
| Rescue Off | `rescue_off` | Off | Radio | Speaks "Rescue -- Off" once when the rescue is over. |

#### When a Rescue Is Spoken

The flight controller reports its rescue as a state: off, or one of the phases pull-up, flip, climb, hover and exit. Leaving *off* for any phase is the start of a rescue and is spoken at once; coming back to *off* is its end and is spoken at once. The phases in between are not spoken, and neither announcement repeats or vibrates: the pilot usually starts a rescue himself, and a confirmation is all it needs. The two switches are independent, so either announcement can be had without the other.

The state comes from the *Rescue State* sensor (92); where the flight controller does not send it, it is taken from *System Status* (120), which carries the same state. Select either under *Configuration* → *Setup* → *Telemetry* (*System Status* is offered there on MSP API 12.10 and later). With neither, nothing is spoken.

Only a change is spoken. A model that connects in the middle of a rescue, or a switch turned on during one, is not announced as a rescue that has just begun; its end is. The announcements do not wait for the model to be armed: a flight controller with rescue enabled (*Flight Tuning* → *Advanced* → *Rescue*) enters it whenever the switch assigned to it is on, so turning that switch on and off with the model disarmed on the bench speaks both, which is a way to check the switch.

---

## Repeat and Haptic

An alert that reports a *condition* -- a voltage that is too low, a temperature that is too
high, a link that has fallen to a level -- keeps speaking while that condition lasts. Two
settings say how, and they belong to the **category page** rather than to one announcement:
the page that switches an alert on is the page that says how it behaves.

| Category page | Repeat / Haptic keys | The alerts they govern |
| --- | --- | --- |
| Voltage | `voltage_repeat`, `voltage_haptic` | Low pack voltage, Main power lost, and the BEC / receiver alert set up under *Setup* → *Power* → *Alerts*. |
| Link Quality | `link_repeat`, `link_haptic` | Link quality, RSSI, Downlink, SNR and Downlink SNR (warning and critical), TX power (warning and critical), Telemetry lost, Telemetry dropouts. |
| ESC & MCU Temperature | `esc_repeat`, `esc_haptic` | ESC temperature and MCU temperature (warning and critical), ESC load (haptic at its critical level only). |
| SmartFuel | `fuel_repeat_below_zero`, `fuel_haptic_below_zero` | The empty battery / fuel alarm below 0%. |

- **Repeat** is *Until cleared*, or a count from 1 to 10. Announcements are ten seconds apart
  either way, except a rise into a level of an alert with two, which is spoken at once; a count simply stops after that many and starts over once the condition has
  cleared, or once an alert with two levels enters a level -- for the low-voltage alert, its
  step into the critical level. *Until cleared* is what every alert did before this setting existed, and is the
  default everywhere except SmartFuel, which kept the single announcement it already had.
- **Haptic** is the transmitter's vibration alongside the voice: one short pulse per
  announcement. It defaults to on for the
  three categories whose alerts already buzzed with no way of switching it off, and to off for
  SmartFuel, which already had this setting and keeps its value.
- **Some alerts have their own rule inside the category, and a setting does not overrule it.**
  The link quality, RSSI, Downlink, both SNR and TX power alerts, the ESC and MCU temperature alerts
  and the ESC load alert buzz at their *critical* level only, never at the warning level. The lost
  telemetry announcement says itself once per loss, so it takes the haptic and ignores the repeat.
  The telemetry dropouts alert takes the repeat and never buzzes.
- **The pack check is not in the table**, because it has no condition to hold: it speaks once
  when the model connects and is latched for the rest of that connection. **Neither is
  Rescue**, whose two announcements are spoken once per change of state.
- **A file the sound pack lacks** leaves its announcement silent and without vibration.
  *Main Power Lost*, *Telemetry Lost* and *Telemetry Dropouts* look for their file first and stay
  silent without one; the latter two log it once per connection. The other alerts in the table
  above count it as made: such an alert is tried again after the usual ten seconds and spends its
  *Repeat* count as if it had spoken, and the log names the file once. The flight timer counts it
  as made for that flight.

## While the Flight Controller Is Silent

When the flight controller stops sending telemetry while the radio link stays up -- a receiver
powered on its own, or a flight controller that stops while powered -- the radio goes on
reporting each of its sensors at the last value it received. An alert judging such a value
would repeat it every ten seconds for a reading nobody sends any more. So the alerts that read
a flight controller value wait while its telemetry frames have stayed away for 6 seconds, the
test *Telemetry Lost* is spoken on (also when that announcement is off):

- **Held:** low pack voltage, *Main Power Lost*, the BEC / receiver alert, ESC temperature, MCU
  temperature, ESC load, the empty SmartFuel alarm, the SmartFuel percentage callouts and the
  SmartFuel level spoken on connect.
- **Not held:** the link alerts (link quality, RSSI, Downlink, both SNR, TX power), which read
  the radio's own link statistics; telemetry dropouts and telemetry lost, which watch the frames
  arriving; the flight timer; the announcements made on a change or once on connect -- arming,
  governor, profiles, rescue, the model name -- which a value that stands still never sets off;
  and the pack check, made once when the model connects.
- **Nothing a held alert has counted starts over.** Its *Repeat* count and its level stand as
  they were, and it is judged again from the first frame that arrives: a SmartFuel step passed
  during the silence, or the level on connect, is spoken then, and *Main Power Back* is still
  announced when the pack reads again. A *Hold* that had begun keeps its start, so a reading
  still past the line when the frames return can be spoken at once.
- A held alert is not spoken, so it raises nothing under *Raise Volume*.
- The test needs the time of the flight controller's last telemetry frame, and a frame received
  since the suite's first audio pass of the current connection: until one has arrived, or with a
  flight controller whose telemetry never records one, nothing is held and *Telemetry Lost* is
  not spoken.

## Raise Volume

With *Mode* set to *Master volume* under *Settings* → *Audio* → *Volume* ([Volume](../pages/settings/audio/volume.md)),
the suite drives the radio's whole volume through a global variable at the *Normal Level*. An
alarm's **critical announcement** is spoken louder: the suite writes the *Alert Level* right
before the file is handed to the radio, and the *Normal Level* again 8 seconds after the last
such announcement. Another one within those 8 seconds extends the time and writes nothing.

- **Which announcement is critical.** The upper level of an alarm with two (link quality, RSSI,
  Downlink, both SNR, TX power, ESC and MCU temperature, ESC load); the only level of an alarm
  with one (main power lost, the BEC / receiver alert, telemetry lost, telemetry dropouts, the
  empty SmartFuel alarm); and the voltage alert from its critical level on, the pack held under the flight
  controller's minimum cell voltage times the cell count for *Hold*, until the alert clears --
  the warning threshold alone does not raise it. Confirmations (telemetry back, main power back,
  the two rescue announcements) and the other announcements never raise it.
- **One switch per alarm**, *Raise Volume*, right under the alarm's own switch (on the SmartFuel
  page, after the empty alarm's *Repeat* and *Haptic*) and shown only while that switch is on; on for
  every alarm except *Telemetry Dropouts*. The BEC and the receiver voltage alert share one, *Raise Volume
  BEC/RX* on the Voltage page, since only one of them is on at a time; that row is always shown, the alert having no switch on
  that page. The switches act only in
  *Master volume*: in *Off* and *Callout level* they change nothing.
- **Only what is spoken raises it.** A reading that stays inside its hold, an alert whose
  *Repeat* count is spent, a file the sound pack lacks, an announcement held back by the quarter of a
  second the suite leaves after handing over the previous one, an alert held while the flight
  controller is silent: none of them raises the volume.
- **Two writes per raise**, one before the announcement and one 8 seconds after the last, each a
  change of the global variable that EdgeTX saves with the model. An alert that repeats every
  10 seconds is back at the *Normal Level* before its next announcement, so each repeat raises it
  again. There is no limit per flight; the alert's own *Repeat* bounds it.
- **The 8 seconds** are an estimate of an announcement with its number and whatever the radio
  still had queued before it; the radio tells a script nothing about what it is still playing.
- **The dashboard and the tool** started from the radio's tool list each keep their own 8 seconds,
  and the radio never runs the two at once: the dashboard stands still while the tool is open. A
  tool closed within the 8 seconds of a raise leaves the volume raised, and the dashboard ends it
  when it runs again: its first pass after a pause of more than 2 seconds reads the global variable and writes the level the dashboard wants if the
  variable holds another -- the *Normal Level*, or the *Alert Level* while a raise of its own is
  still running -- also while the dashboard waits for the model or stands behind another screen of
  the radio. The tool reads it the same way
  when it starts.
- **The tool opened from the dashboard** runs inside the dashboard and makes no announcements of
  its own. While it is open, the volume is not refreshed: a raise standing when it opens lasts
  until it is closed, and ends on the dashboard's next pass once its 8 seconds are over.
- **Vibration is not affected**: *Haptic* stays the page's, whether or not the volume is raised.
- With *Connected only* on, the link going down writes `-1024` at once, raised or not.

---

## Sound Pack Files

Announcements are played from the sound pack under `/SOUNDS/rf/<language>/`. Numbers and their units are spoken by the radio itself, so they follow the language set on the radio rather than the language of the pack.

Every announcement has a file of its own in both packs. Ten have no substitute and stay silent in an older pack that lacks theirs:

| File | Announcement |
| --- | --- |
| `stat/alerts/telemetrylost.wav` | Telemetry lost |
| `stat/alerts/telemetryok.wav` | Telemetry recovered |
| `stat/alerts/txpower.wav` | TX power, followed by the percentage |
| `stat/alerts/rssi.wav` | RSSI headroom |
| `stat/alerts/downlink.wav` | Downlink headroom |
| `stat/alerts/snr.wav` | SNR |
| `stat/alerts/downlink_snr.wav` | Downlink SNR |
| `stat/alerts/dropouts.wav` | Telemetry dropouts |
| `stat/alerts/rescue_on.wav` | Rescue -- Active |
| `stat/alerts/rescue_off.wav` | Rescue -- Off |

Three have a file of their own in both packs, and fall back to another file in an older pack that lacks it:

| Preferred file | Falls back to | Announcement |
| --- | --- | --- |
| `stat/alerts/mainpower.wav` | `stat/alerts/batteryempty.wav`, then `stat/alerts/lowvoltage.wav` | Main power lost |
| `stat/alerts/mainpowerok.wav` | `evt/battery.wav` | Main power back |
| `stat/alerts/notfull.wav` | `stat/alerts/voltage.wav` | Pack not full |

`stat/alerts/batteryempty.wav` is in the English pack only, so a German pack that lacks `stat/alerts/mainpower.wav` falls back straight to `stat/alerts/lowvoltage.wav`.

---

*Documented against RFSuite 0.1.7.*
