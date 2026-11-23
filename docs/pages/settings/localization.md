---
title: Localization
sidebar_label: Localization
sidebar_position: 30
---

# Localization

The language RFSuite runs in, and the unit formats its readouts use. Left on *Automatic*, the
language follows the card or the radio instead of being pinned to one value.

## Where to find it

*System* → *Settings* → *Localization*

Always available.

## Settings

| Setting | What it does |
| --- | --- |
| Language | *Automatic* (the default) follows the card's own language on a packaged build, and the radio's language setting when the suite runs from source or in the simulator. *English* or *German* pins the language instead: the choice is stored on the radio and wins over the automatic resolution. |
| Temperature Unit | *Celsius* or *Fahrenheit* for every temperature the suite shows — the flight log's columns, the dashboard's gauges and text readouts, and the ESC and MCU temperature levels under *Audio > Events* — and for the temperature the ESC and MCU alerts speak. |
| Altitude Unit | *Meter* or *Feet*. Stored like the other two, but nothing reads it yet, so it changes no readout today. |

## Notes

- A save the card refuses shows *Save failed: the settings file could not be written to the SD
  card*, and nothing on the page has been stored.
- Only an explicit choice is written. *Automatic* is the **absence** of the `language` key in
  `preferences.lua`, which is what the resolution reads; choosing *Automatic* again removes the
  line and hands the decision back to the card or the radio. It is the only way back from this
  page, and saving the page for another reason -- a unit change, say -- never writes the key.
- **What the setting steers depends on how the suite was installed.** On a packaged card the
  package decides the language of the screen -- every label is a literal by then -- and this
  setting chooses the language of the **announcements**, from the `SOUNDS/rf/<language>` folder.
  Run from source or in the simulator it also sets the tool's own language, from the next start
  of the tool.
- **Each archive carries the announcements of its own language only.** Announcements in the other
  language need that language's `SOUNDS/rf/<language>` folder, copied from its archive onto the
  card, and copied again after every update, since nothing refreshes it. Without it every
  announcement whose file the chosen folder lacks plays from the package's own language instead
  -- the English folder when the suite runs from source -- so a missing folder changes the voice
  rather than silencing an announcement the package's own pack can play.
- **Not even the voice changes while the tool runs.** An announcement resolves its folder once and
  keeps it for the life of the Lua state, so one that has already played stays in the old language
  until that state is created again. Announcements that have not played yet use the new one.
- The two unit settings do not reach the flight controller; they are settings of this radio and
  apply to every model.


Related: [configuration-files.md](../../reference/configuration-files.md) for the file itself and
what the suite keeps in it.

*Documented against RFSuite 0.1.7.*
