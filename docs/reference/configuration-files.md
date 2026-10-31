---
title: Configuration files
sidebar_label: Configuration files
---

# Configuration files

Everything you change in the suite is kept in two files on the radio's SD card, under
`/SCRIPTS/TOOLS/rfsuite.user/`:

| File | What is in it |
| --- | --- |
| `preferences.lua` | The settings that belong to the transmitter: the announcements, the units and language, the preview switches, the logging level, which dashboard theme is shown and whether a model may override it. |
| `<mcu id>.lua` | The settings that belong to one flight controller, named after the board's own id — the battery, the per-model theme override and its configuration, the in-flight tuning setup, what the setup assistant has been told about the machine, and the name the board calls itself by. One file per board. |

You do not have to touch either of them. They are written when you press *Save*, and reading
them is all the suite needs at startup.

## Which file belongs to which helicopter

A per-flight-controller file is named after the board's own id, which is a long hexadecimal
number and tells you nothing about the machine it is bolted into. So the suite writes the
model name the flight controller reports into the file as well, the first time it connects to
a board with the configuration tool open or with the [background telemetry
decoder](background-decoder.md) running:

```lua
  craft = {
    name = "Goblin 630",
  },
```

That is the name set in the flight controller — the one the *Synchronize Model Name* setting
puts on the radio's model — and not the name of the radio model. It is written again whenever
it changes, and not otherwise.

**A flight controller that has no name set gets no such line.** The suite does not invent one,
because a placeholder in the file could not be told apart from a helicopter actually called
that, and it would then never be corrected. So a file without a `craft` block simply belongs to
a board that has not been given a name.

## They are Lua, not INI

Both files are a small Lua program that returns a table, so the radio can read one without
picking it apart line by line:

```lua
-- RFSuite preferences. This file is Lua data, not an INI: strings keep their
-- quotes, booleans are true or false, and the return line stays. Rewritten whole on save.
return {
  general = {
    debug_level = "off",
    save_confirm = true,
  },
  localizations = {
    temperature_unit = 0,
  },
}
-- generation 7 ......
```

That matters for what a widget costs. The dashboard re-reads the settings whenever they change,
inside a call the radio stops at a fixed instruction count — and taking a file apart line by
line is by far the most expensive thing it did there. Reading a real 88-key settings file used
to cost about half of everything one dashboard call is allowed; it now costs a sixteenth of it,
and it no longer grows meaningfully with each setting a release adds.

### Editing one by hand

It is a text file and you may edit it, with the radio switched off or the tool closed. Three
rules, and they are the ones Lua enforces:

- **Text needs quotes**: `debug_level = "info"`. A bare word is read as a name and there is
  nothing for it to name.
- **Yes and no are `true` and `false`**, without quotes. Numbers are written plainly: `30`,
  `3.2`.
- **Keep the frame**: the `return {` at the top, the `}` at the bottom, and a comma after every
  entry.

The file is rewritten whole on the next save, so a comment you add to it does not survive and a
setting the suite does not know about is dropped. The `-- generation` line at the end is the
suite's own; it changes on every save so that the dashboard can see that something was written.

**If a hand edit breaks the file**, nothing is lost and nothing crashes: the suite falls back to
its built-in defaults for that file, writes the reason and the line number to the log, and the
next save replaces the file with a correct one. The one thing to know is that the settings that
were in it are then gone — so keep a copy before editing.

### The developer section

`preferences.lua` may carry a `developer` section that no page writes. Its values are put there
by hand, and a save keeps whatever the section holds.

```lua
  developer = {
    precompile = false,
  },
```

- **`precompile`** — whether the suite compiles its installed files ahead of use. Absent or
  `true` is the normal behaviour: after an install or an update the configuration tool's start
  screen, or the dashboard's connection splash if the dashboard starts first, reads *Preparing
  suite* until every file has its compiled copy beside it, so no page pays for that later. The
  dashboard connects to the flight controller only once that has finished; when the tool is
  opened from the dashboard meanwhile, its start screen shows the same pass rather than starting
  another. After an install or an update the dashboard then reads *Suite updated. Please restart
  the radio.* and does not connect until the radio has been restarted, and the tool shows the same
  request once when its start screen closes: what was loaded before the pass is still the previous
  build's code, and only a restart replaces it. This applies to an install made from the release
  archive, which carries the build identity; a source tree copied by hand is compiled but never
  holds the dashboard back. `false` skips this in both places: the start screen and the splash wait for the
  connection only, and each file is compiled the first time a page needs it, which makes that
  first opening slower. It is meant for automated test runs on a card that starts without
  compiled files every time; on a radio there is no reason to set it.
- **`mspexpbytes`** — how many bytes the developer page *MSP Experiments* edits. Absent means
  16, which is also the most it handles. Like `precompile` it is only read, and set by hand.

## Coming from an earlier release

Earlier releases kept the same settings in `preferences.ini` and `<mcu id>.ini`, and the model
names in `model_name_restore.ini`. The files are **brought across the first time the
configuration tool is started**, or by the [background telemetry
decoder](background-decoder.md) on a radio that runs it. Until one of those has happened, the
former file is read exactly as it was before and nothing is written — so a radio that is
switched on and flown without opening the tool behaves as it always did, and the settings are
there either way.

What the migration does:

- the values are read out of the `.ini` and written into the `.lua` beside it,
- the `.ini` is kept, renamed to `.ini.bak`, for one release,
- settings that no longer exist in the suite are not carried over — that is deliberate, and it
  is what stops a file from growing for ever. A whole section that no longer exists goes the
  same way: an older `preferences.ini` may still carry `[audio_switches]` and `[audio_timer]`,
  and neither is written into the new file,
- a `preferences.luac` left behind by an earlier loader is deleted, because the radio would
  prefer that stale compiled copy to the file you can read.

There is nothing to do and nothing to confirm. You can delete the `.ini.bak` files once you are
happy; the suite never reads them again.

The dashboard widget does not do the migration itself, and that is deliberate: the radio stops
a widget after a fixed amount of work, and reading a settings file in the old format is more
than that allowance — so a widget that tried would be stopped half way, every time, and never
finish. The tool and the background decoder are not stopped that way.

## The other files beside them

- `journal/<mcu id>.lua` — the append-only [change journal](change-journal.md), recording each value committed by the Tune Advisor.
- `tune/<mcu id>.lua` — the [Tune Advisor](../pages/flight_tuning/tune_advisor.md)'s saved flights, the last 5 per
  flight controller, written by the dashboard or the service widget after each disarm. Lua data read with an
  environment of its own, never run as a script: a version line `v(1)`, then one `f(...)` line per flight and axis.
  Each save writes `<mcu id>.lua.new` beside it, checks its size and renames it into place, keeping the previous
  file as `<mcu id>.lua.bak` until the next save. If a save is cut short after the old file was renamed to `.bak`
  and before the new one was in place, the flights are read from the `.bak` and the next save writes them back.
  Deleting the file and its `.bak`, or *\** on the page, forgets the flights.
- `reload.req` — a few bytes the tool writes when you save, so the dashboard widget knows to
  re-read the settings. Unchanged by the move to Lua files. Do not delete it while the suite is
  running.
- `model_name_restore.lua` — the model names the suite has renamed while a craft was connected
  and has to put back afterwards, one entry per model of the radio, named after the model file
  it belongs to. The same Lua data as the two above, written and read the same way, and a card
  from an earlier release has its `model_name_restore.ini` brought across on the first read with
  the same `.ini.bak` left beside it. It is a file of its own rather than a section of
  `preferences.lua` because it is written while you fly, and every write to `preferences.lua`
  makes the dashboard re-read its settings.
- `precompiled.txt` — which installed build was last compiled, written when *Preparing suite*
  finishes, whether the tool or the dashboard ran it. A later start compiles everything again only
  when the installed build differs from it, so deleting it costs one slower start and nothing else.
  The dashboard reads only this file and the build identity beside the core: on a build already
  compiled it does no further work and connects at once, and a single source edited on the card
  is compiled by the tool's next start. On a fresh card
  where nothing has been saved yet, the tool creates this folder to write it.
  The pass leaves out the `._` files macOS writes beside every file it copies onto a card,
  and a file that does not compile is named in the log, once per start.
- `preferences.lua.tmp`, `<mcu id>.lua.tmp` or `model_name_restore.lua.tmp` — a save that was
  interrupted, by a power cut at exactly the wrong moment. The next read finishes it; you should
  never see one for long. If a write fails or the card is full, the temporary file is removed
  immediately and the existing configuration is kept intact.

## Related

- [Background telemetry decoder](background-decoder.md)
