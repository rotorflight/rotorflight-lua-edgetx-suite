---
title: Background service and the service widget
sidebar_label: Service widget
---

# Background service and the service widget

Much of what RFSuite does happens in the background, not on a page: it keeps the MSP link to
the flight controller, runs the connect chain that reads the flight controller's configuration
when the link comes up, decodes the custom telemetry sensors, runs the events on arming and
disarming, and speaks the voice announcements. That work only advances while something on the
radio calls into it. This page explains what does, which widget to put on a model, and what to
avoid.

## What runs the background work

Three things can, and at least one of them has to be running:

| What | When it runs the background work |
| --- | --- |
| The configuration tool | Only while it is open. Closing the tool stops it. |
| The **RFSuite** dashboard widget | Whenever it is on one of the model's screens, also while that screen is not the one shown. EdgeTX calls every widget of the model on each refresh, visible or not, and the dashboard does the same background work in both cases. |
| The **RFSuite Service** widget | Whenever it is on one of the model's screens, visible or not, and the dashboard is not running on the same model (see [Both widgets on one model](#both-widgets-on-one-model)). It does nothing else besides drawing a small status tile. |

With none of them running — no widget on the model and the tool closed — there is no link: the
custom sensors are not decoded, no connect events run, and no announcements are spoken.

EdgeTX keeps the screen layout per model, so the choice below is made once for every model you fly
with RFSuite.

## Which widget to add

| You want … | Add | Setup of the background service |
| --- | --- | --- |
| The dashboard | **RFSuite** on a screen of the model | None. The dashboard runs it. *RFSuite Service* is not needed as well. |
| No dashboard | **RFSuite Service** on a screen of the model (recommended) | None beyond placing the widget. |
| Neither | — | The link, the sensors and the announcements only work while the tool is open. |

### With the dashboard

1. In the model's screen setup, add a screen; a full-screen layout suits the dashboard best.
2. Choose **RFSuite** as the widget for it.
3. Optionally pick a theme in the tool under *System* → *Settings* → *Dashboard* → *Theme*
   (see [Themes](themes.md)).

Nothing else needs to be set up for the background work.

### Without the dashboard

1. In the model's screen setup, pick a small zone on a screen you do not otherwise use.
2. Choose **RFSuite Service** as the widget for it.

The widget has no options. Its settings — which announcements are spoken, for example — are the
suite's own and are changed in the tool; the widget picks up a change within about 30 seconds,
and not while the model is armed.

## What the service tile shows

The tile carries the title *SERVICE*, one status line and, once it is known, the model name the
flight controller reports.

| Status | Meaning |
| --- | --- |
| Waiting for MSP link | No link to the flight controller yet: the receiver is off, not bound, or the telemetry link is down. |
| Loading data... (n/m) | Linked; the connect chain is reading the flight controller's configuration, step *n* of *m*. |
| No MSP reply | The link is up, but the flight controller did not answer an MSP request while the connect chain was running. |
| MSP API x.y not supported | The flight controller's firmware is older than RFSuite supports (see the requirements in the README). |
| Connected | Linked, and the connect chain has finished. |

## Both widgets on one model

With *RFSuite* and *RFSuite Service* on the same model, the dashboard does the background work and
writes the log to the card, and the service widget stands down: its tile still shows the status, but
it runs nothing itself. The service widget is then not needed and can be removed.

If the dashboard is taken off the model, or stops running, the service widget notices within about
half a second and takes the work over, the log to the card included. A flight that stays armed
across the change keeps its full flight time.

## What not to do

- **Do not rely on the tool alone if you want announcements or the custom sensors in flight.**
  Without one of the two widgets, everything stops when the tool is closed.
- **Do not keep a background job of the earlier Rotorflight Lua scripts in the model.** With an active `rf2bg` entry in the model's special functions the suite adds no [background decoder](../reference/background-decoder.md), and both then write the same sensors. An entry that is switched off neither runs nor holds the suite's back. Remove an active entry; the suite adds its own `rfsbg` at the next connect where a slot is free, it runs from the next model load, and that one stays.
- **Do not skip the restart after an install or an update.** The first start compiles the
  installed files; afterwards the dashboard and the service widget do not connect until the
  radio has been restarted, because the code they loaded before is still the previous build's.
  The tool asks for the restart once its start screen closes, and the dashboard shows
  *Suite updated. Please restart the radio.* (see [Configuration files](../reference/configuration-files.md)).

## Related

- [Dashboard widget](README.md)
- [Standby screen](standby-screen.md) — what the dashboard shows while it waits for the flight
  controller.

*Documented against RFSuite 0.2.2.*
