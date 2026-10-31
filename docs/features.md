---
title: Features
sidebar_label: Features
sidebar_position: 10
---

# Features

What RFSuite does, in one place, with a link to the page that describes each part. RFSuite
configures a Rotorflight flight controller from an EdgeTX colour transmitter over the model's
CRSF telemetry link, and the same installation brings a dashboard widget and voice
announcements. Requirements and installation are in the
[README](../README.md).

A feature marked *preview* is hidden until it is switched on under *System* → *Settings* →
*General*. Pages that change the flight controller are read-only while the model is armed, and
a page that needs a newer MSP API than the flight controller reports is hidden. The full menu,
entry by entry, is in the [menu structure](reference/menu-structure.md).

## Configuring the flight controller

Every page reads the flight controller first and writes nothing until *Save* is pressed; how a
save works is described in [Saving](reference/saving.md).

| Area | What it covers |
| --- | --- |
| Flight Tuning | [PIDs](pages/flight_tuning/pids.md), [Rates](pages/flight_tuning/rates.md), [Governor](pages/flight_tuning/governor.md), and under *Advanced* [Filters](pages/flight_tuning/advanced/filters.md), [PID Controller](pages/flight_tuning/advanced/pid_controller.md), [PID Bandwidth](pages/flight_tuning/advanced/pid_bandwidth.md), [Autolevel](pages/flight_tuning/advanced/autolevel.md), [Main Rotor](pages/flight_tuning/advanced/main_rotor.md), [Tail Rotor](pages/flight_tuning/advanced/tail_rotor.md), [Rescue](pages/flight_tuning/advanced/rescue.md) and the [advanced rate settings](pages/flight_tuning/advanced/rates_advanced/advanced.md). |
| Tune Advisor | [Suggestions for each axis](pages/flight_tuning/tune_advisor.md) from the last 5 acro flights, saved at each disarm from what the flight controller measured, applied with *Save* and recorded in the [change journal](reference/change-journal.md). Needs MSP API 12.10 and firmware with the packed tune advisor reply. |
| Setup | Configuration, Radio Config, [Telemetry](pages/setup/telemetry.md), [Accelerometer](pages/setup/accelerometer.md), [Alignment](pages/setup/alignment.md) with auto-align on MSP API 12.10, [Ports](pages/setup/ports.md), GPS and [Model](pages/setup/model.md). |
| Mixer and servos | Swash, swash geometry, tail and trims; PWM and bus servo outputs. |
| Controls | [Modes](pages/setup/controls/modes.md), [Adjustments](pages/setup/controls/adjustments.md), [Failsafe](pages/setup/controls/failsafe.md), beepers, blackbox with its [status](pages/setup/controls/blackbox/status.md), and flight statistics. The flight controller's half of [in-flight tuning](dashboard/inflight-tuning.md) (preview) is set up from the tuning screen on the dashboard. |
| Power | [Battery](pages/setup/power/battery.md), alerts, [Sources](pages/setup/power/sources.md), [SmartFuel](pages/setup/power/smartfuel.md) and [Preferences](pages/setup/power/preferences.md). |
| ESC & Motors | [Throttle](pages/setup/esc_motors/throttle.md), [ESC telemetry](pages/setup/esc_motors/telemetry.md) with wiring detection on MSP API 12.10, RPM, Motor Override, and the ESC configuration pages for [AM32](pages/setup/esc_motors/esc_tools/escmfg/am32.md), [BLHeli_S](pages/setup/esc_motors/esc_tools/escmfg/blheli_s.md), [Bluejay](pages/setup/esc_motors/esc_tools/escmfg/bluejay.md), [Flyrotor](pages/setup/esc_motors/esc_tools/escmfg/flrtr.md), [Hobbywing V5](pages/setup/esc_motors/esc_tools/escmfg/hw5.md), [OMP](pages/setup/esc_motors/esc_tools/escmfg/omp.md), [Scorpion](pages/setup/esc_motors/esc_tools/escmfg/scorp.md), [XDFly](pages/setup/esc_motors/esc_tools/escmfg/xdfly.md), [YGE](pages/setup/esc_motors/esc_tools/escmfg/yge.md) and [ZTW](pages/setup/esc_motors/esc_tools/escmfg/ztw.md), each unlocked for the ESC telemetry protocol the flight controller reports. |
| Governor | [General](pages/setup/governor/general.md), [Ramp Time](pages/setup/governor/time.md), filters and bypass curve. |
| Profiles | [Copy Profiles](pages/tools/copy_profiles.md) and [Select Profile](pages/tools/select_profile.md) for flight and rate profiles. |

## Dashboard

The *RFSuite* widget draws live telemetry on the transmitter's main screens, with a separate
screen before, during and after a flight. The [dashboard section](dashboard/README.md) has
the details.

- [Ten shipped themes](dashboard/themes.md), chosen for the radio or per model, among them
  [Urban](dashboard/urban-theme.md), [Grid](dashboard/grid-theme.md) and
  [Deck](dashboard/deck-theme.md); and [user themes](dashboard/user-themes.md) copied from a
  shipped one and edited.
- Customizable: on [*Settings*](pages/settings/dashboard/settings.md) each theme offers its
  own pages — what every value tile shows before the flight, in flight and in the post-flight
  statistics, the full-screen keys, colours and the battery range its gauges span. Urban, Grid
  and Deck can show any of the radio's telemetry sensors by name in a row or a tile. These are
  standard values for every model, and a model can change them for itself on
  [*Per-Model Settings*](pages/settings/dashboard/overrides.md).
- In full screen: a [quick menu](dashboard/quick-menu.md) for the flight line,
  [keys](pages/settings/dashboard/keys.md) that apply to every theme, and an optional
  [standby screen](dashboard/standby-screen.md) shown before the flight controller is ready.
- The [in-flight tuning overlay](dashboard/inflight-tuning.md) (preview), which steps the
  flight controller's adjustment functions through two global variables while flying.
- A model image and caption, resolved as the README describes under *Model images*.
- An event log on Urban's [status page](dashboard/urban-theme.md): arming and disarming, the
  connection, and every change of the governor state and the ESC's verdict, with the radio's
  time.
- The *RFSuite Service* widget keeps the link and the announcements running while the tool
  is closed.

## Voice announcements

Ten categories, each switched on its own page under *System* → *Settings* → *Audio* →
*Events*: connect, arming, governor, voltage, profiles, ESC and MCU temperature, adjustments,
SmartFuel, link quality and [rescue](pages/settings/audio/events/rescue.md). What each one says
and when is in [Audio events](audio/events.md); how loud they play is the
[Volume](pages/settings/audio/volume.md) page.

## Logs and diagnostics

- [Flight Log](pages/tools/flight_log.md): one line per flight, written when the model
  disarms, with its model, pack, armed time and what its telemetry reached; browsed by flight,
  by model and by pack. Its battery registry counts each pack's cycles, the pack is picked on
  the dashboard after connecting or from the quick menu, and the flight controller can be
  moved onto that pack's battery profile. Off until *Write a flight log* is switched on.
- [Logs](pages/logs.md): the transmitter's own telemetry logs on the SD card, with a flight
  summary and a graph of up to four columns.
- Diagnostics: flight controller and Rotorflight status, [ELRS Link](pages/tools/diagnostics/elrs_link.md),
  [Validate Sensors](pages/tools/diagnostics/validate_sensors.md),
  [SmartFuel](pages/tools/diagnostics/smartfuel.md),
  [CRSF Sensors](pages/tools/diagnostics/crsf_sensors.md),
  [System Status](pages/tools/diagnostics/system_status.md),
  [Session Logs](pages/tools/diagnostics/session_logs.md) and
  [Info](pages/tools/diagnostics/info.md).
- The [connection button](reference/connection-status.md) in the header, which says what the
  connection is doing and what went wrong.

## Settings and language

English and German user interface, and the unit formats of the readouts, on the
[Localization](pages/settings/localization.md) page. The settings the suite keeps on the SD
card are described in [configuration files](reference/configuration-files.md).

*Documented against RFSuite 0.2.2.*
