---
title: Theme
sidebar_label: Theme
sidebar_position: 10
---

# Theme

Which dashboard theme the widget shows, and whether a model may use a theme and theme settings
of its own. The theme chosen here is the one every model shows unless it has settings of its own.

## Where to find it

*System* → *Settings* → *Dashboard* → *Theme*

Always available. The rows for the connected model need a flight controller that has been read,
because a model's own values are stored in the file named after that flight controller.

## Settings

### Dashboard Theme

| Setting | What it does |
| --- | --- |
| Theme | The dashboard theme of every model without settings of its own. A theme covers all three flight phases — before, during and after the flight — itself. |
| Inflight Override, Postflight Override | Only while *Per-Phase Themes* is on. A different theme for that one phase; left at *Use theme above*, the phase keeps the theme above. |

### Per-Model Settings

| Setting | What it does |
| --- | --- |
| Allow per-model settings | Whether any model on this radio may use its own theme and its own theme settings. Off, every model shows the theme above with the standard theme settings, whatever its own file holds. |
| *(a note)* | Only while *Allow per-model settings* is on and no flight controller has been read: a model's values cannot be set without one. |
| *Model:* and the name | Only while *Allow per-model settings* is on and a flight controller is connected: the craft name the flight controller reports, or the radio's model name where it reports none. |
| Own settings for this model | Only while *Allow per-model settings* is on and a flight controller is connected. Turns the connected model's own theme and theme settings on. |
| Theme | Only while *Own settings for this model* is on. The connected model's theme; *Disabled* keeps the theme of the section above. |
| Inflight Override, Postflight Override | Only while *Own settings for this model* and *Per-Phase Themes* are on. The same phase overrides as above, for this model. |

The model's own theme settings are edited under
[*Dashboard* → *Settings* → *Per-Model Settings*](overrides.md).

### Advanced

| Setting | What it does |
| --- | --- |
| Per-Phase Themes | Adds the inflight and postflight overrides to both theme sections. Off by default; turning it off keeps the overrides stored and ignores them. |

## Notes

- **Switching off keeps the values.** Turning *Allow per-model settings* or *Own settings for this
  model* off does not delete anything: the model's theme and theme settings stay in its file and
  are ignored until the switch is on again.
- **A card from an earlier version** has neither switch stored. A model keeps what it already
  used: one that had a theme of its own (the former *Model Override* switch) or any theme setting
  of its own still uses them. The page shows *Allow per-model settings* as whatever the connected
  model does — off when no flight controller is connected — and stores it only once it is
  changed, so saving the page for another reason leaves every model as it was. Switching it off
  and saving turns the per-model values off for every model on this radio, without deleting them.
- *Own settings for this model* is also written under the key the former *Model Override* switch
  used, so an older version of the suite on the same card still shows the model's theme.
- Saving writes the radio's file and, with a flight controller connected, the model's file. The
  page reports *Saved* only when both were written, and otherwise *Save failed* with the reason:
  *the settings file could not be written to the SD card* where the card refused a file.
- **The post-flight screen keeps the model's theme after the battery is unplugged.** A model with
  a theme of its own shows that theme on its post-flight screen also once the flight controller
  has stopped answering, until the next flight controller connects, also when a Setup > Power
  page is opened from the dashboard in that stretch. Its model-specific theme settings stay
  too, even when the disconnected session has released the model's file. Settings the model
  does not override still follow the radio's values. The next connection clears this retained
  context before loading another model.
- **On a reconnect the dashboard chooses its theme once the flight controller has identified
  itself.** Until then the connection screen stays up, so a model with a theme of its own goes
  straight back to that theme instead of passing through the radio's theme first and loading its
  own from the SD card again. A flight controller that does not identify itself gets the radio's
  theme.
- **The theme list is kept between visits.** The page lists the theme folders when it is first
  opened and keeps that list while the tool runs, until the tool drops the page from its cache of
  recently opened pages. The page has no *Reload*: a theme copied onto the card while the tool is
  open is offered once the tool has been closed and opened again.

## Related

- [Settings](settings.md) — the theme settings, standard and per model.
- [Dashboard themes](../../../dashboard/themes.md) — every theme that ships with the suite, with a
  picture of each of its three screens.

*Documented against RFSuite 0.1.7.*
