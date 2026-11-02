---
title: Adding an announcement
sidebar_label: Audio announcements
sidebar_position: 70
---

# Adding an announcement

Everything the suite says out loud is decided in one file, `src/rfsuite/lib/audio.lua`, and
switched on from one settings page family, `src/rfsuite/app/pages/settings/audio/events/`. An
announcement is four things: the condition that fires it, the switch that allows it, the words in
both locales, and the WAV file. This page is the checklist for all four.

## Where the engine runs

`Audio.process(self, opts)` is called from two places, and they hand it the same shape:

| Caller | When |
| --- | --- |
| `widgets/dashboard/runtime.lua`, `processAudioEvents` | every logic tick while `startupComplete`, except a tick that runs the telemetry read while logic ticks come closer together than the read interval: that call is made on the next tick instead (#439) |
| `ui/home.lua`, the audio block | every 200 ms while the tool has a connection |

`self` carries `audioState` (the engine's own memory), `preferences` (the radio's settings) and
`state` (the telemetry snapshot). **Both callers must supply the same fields under the same
names**, or an announcement works under the widget and is silently mute under the tool. That
symmetry is the reason the tool builds its `telemetryState` the way the widget's `readTelemetry`
does, rounding included; if you read a new field, check both sides write it.

**A sensor that only your announcement needs is read only while it is switched on.** Both callers
read their telemetry over and over, and a sensor the radio does not carry costs a name search each
time it is retried. So the announcement says whether it wants the reading -- the dropouts alert sets
`audioState.dropoutsWanted` on every pass of `Audio.process` -- and both callers read the sensor
only while that flag is set, and leave the field nil otherwise:

```lua
if audioState and audioState.dropoutsWanted then
  state.skippedFrames = getSensor("skipped_frames")
else
  state.skippedFrames = nil
end
```

A radio that never switches the announcement on then pays nothing for it. The first pass after it
is switched on reads nothing yet; the reading arrives one pass later.

`Audio.process` throttles itself to 0.25–0.60 s depending on the screen height, so it is cheap to
call and you do not need a throttle of your own. Under the widget a call that would share a pass
with the telemetry read waits one logic tick (0.1 s), so two passes can be that much further apart
than the throttle says, and an announcement can come one tick later than it otherwise would.
What you do need is a re-alert interval: every repeating alert in the file uses **10 seconds**,
kept in `audioState.lastAlertAt.<key>`.

`Audio.resetConnectionState(audioState)` runs when a connection goes down. Anything your
announcement latches — "already said once this session", "the threshold is currently breached" —
belongs in that function's clear list, or it will carry into the next flight.

A reading only one alert uses is read only while that alert is on: the engine sets a flag on
`audioState` (the TX power alert's `txPowerWanted`) and both callers read the sensor into `state`
while it is set, and give nil otherwise. A radio with the alert off then pays no sensor search.

An alert that needs something the transmitter module knows but no telemetry frame carries asks
the module itself. The TX power alert reads the module's Max Power and dynamic-power setting
through the bounded, read-only provider in `lib/elrs_config.lua`; `lib/elrs_power.lua` decodes the
completed fields. Every frame sent replaces one RC channels frame, so the alert sends nothing
while the model is armed, sends at most one request per pass, and waits until the connection
sequence is complete. The provider
serializes each parameter conversation with an owner lease because replies carry no transaction
ID. The diagnostics page, standby screen, and TX-power alert therefore take turns instead of
consuming one another's replies, and share only completed snapshots. An explicit refresh first
quarantines copied replies left in that owner's queue: a quarantine pass pops exactly one
Parameter Entry (`0x2B`) and never pops Device Info (`0x29`). A normal pass pops at most two
replies and sends at most one request. A read stops after four accepted discovery pings, 48 total
push attempts across discovery and parameter reads, 48 fields, eight chunks per field, or 512
bytes per field. The first read of a module walks the parameter list by name; the field ids it
found are kept per module (name, versions and field count off its device information) while the
provider is loaded, and later reads ask for those fields directly. A kept id that names another
field is forgotten and the list is walked again. The alert cancels its owned read while armed or before the connection sequence is
complete, and starts a fresh owned read after those conditions clear.

The provider is one shared singleton, and it stays loaded only while the standby screen or the
TX power alert uses it. When the last standby screen closes with the alert off, the dashboard
unloads it from the module registry together with `lib/elrs_power.lua`; `Audio.releaseElrsConfig`
first drops the alert's own reference, so the next user loads one fresh instance rather than a
second one beside the old. It is unloaded only while it is idle: while another consumer holds its
lease, or late replies of a read cut short by the exit are still to be drained, it stays, and the
dashboard drains it and tries again on later passes. With the alert on, the provider stays.
`lib/crsf.lua` stays loaded in
either case: the MSP transport and the telemetry drain share that one frame multiplexer. Its
retained protocol state is bounded to at most one active transaction and one last snapshot
containing the four matched fields. On desktop Lua 5.3 with the accounting stubs, the heap after
leaving standby is 9.2 KiB above the level before it with the alert off, and 37.5 KiB with it on.
**An announcement measured against the air rate** -- the RSSI and Downlink headroom alerts -- needs
the row of `lib/link_rates.lua` for the rate the link runs. `linkRateRow` in `lib/audio.lua` resolves
it from the `RFMD` reading on the state and the transmitter module's ExpressLRS generation, which
`LinkRates.resolveGeneration` asks the module for once per connection and keeps on the same state
(`linkGeneration`, `linkPingSent`) -- the fields the dashboard's own link sources use, so a theme and
an announcement on the widget share one ping. The tool clears those fields where its connection goes,
the widget where a new flight-controller connection starts, and both read the sensors only these alerts use -- `ANT` and `TRSS` only while
`audioState.linkHeadroomWanted` says one of them is on. The SNR and Downlink SNR alerts are two more
entries of `LINK_HEADROOM_ALERTS` (`snr = true`): they read the row's `snrUp` / `snrDn` columns through
`LinkRates.snrPercent`, take one dB of that scale as their hysteresis (`LinkRates.snrPointsPerDb`, so a
level is left only more than one dB above its line; `announceLinkHeadroom` waives it for a reading at
the top of the scale, which clears every level set below 100 %), and
read `RSNR` and `TSNR` only while `audioState.linkSnrWanted` says one of them is on (`RFMD` while
either flag is). Add a further alert of that kind as one more entry of `LINK_HEADROOM_ALERTS`, or read
its own column off the same row.

## The switch

Every switch is one row in `CONFIG_SCHEMA` in
`app/pages/settings/audio/events/category_page.lua`. That one table is the single source of
truth: it says the key, the type, the default, the valid range and which page draws it.

```lua
{ key = "mcu_temperature", type = "bool",   default = false, section = "esc" },
{ key = "mcu_threshold",   type = "number", default = 80, min = 40, max = 150, section = "esc" },
```

Then one item in `SECTIONS[<section>].items` decides how it is drawn — `bool`, `number`,
`choice` or `subheader`, with `labelKey`/`labelFallback`, an optional `suffix`, and either
`enabledBy` (drawn always, editable only while that switch is on) or `requires` (not drawn at
all while that switch is off).

The generic path covers `bool` and `number` rows. A `choice` row is generic only when it is a
Repeat setting: the page supplies `getRepeatOptions`, `getRepeatGetter` and `getRepeatSetter` for
every choice key that is not handled explicitly. Adding another kind of choice therefore also
requires its own option list, getter and setter, plus a branch in the `item.kind == "choice"`
block that selects those functions.

The three current special choices show the complete pattern:

- `fuel_callout_percent` uses `getFuelCalloutOptions`, `getFuelCalloutGetter` and
  `getFuelCalloutSetter`. Its values must also be present in `FUEL_CALLOUT_VALUES`; loading and
  the getter fall back to 10 when a stored value is outside that set.
- `voltage_announce` uses `getAnnounceOptions`, `getAnnounceGetter` and `getAnnounceSetter` for
  the Pack/Cell pair. The getter and setter normalize every other value to Pack (`0`).
- `tpwr_max` uses `getTxPowerMaxOptions`, `getTxPowerMaxGetter` and `getTxPowerMaxSetter`. Add a
  supported power to `TX_POWER_MAX_LIST`; `TX_POWER_MAX_VALUES` is derived from that list, and a
  stored value outside it falls back to 100 mW.

The choice setter is also where its enabling rule is enforced: the fuel step is editable only
with `fuel_alerts`, and the TX-power maximum only with `tpwr_limit`. Keep that guard aligned with
the row's `enabledBy` value. Loading, saving and the per-page split remain generic after these
choice-specific pieces are supplied. A field marked `scope = "model"` is stored with the model
rather than with the radio.

The engine reads the same keys through `prefEnabled(events, "key", default)`, and **the default
passed there must match the schema's**, because a settings file written before your key existed
has no value for it. `[audio_events]` is an open section of the radio-wide store
(`lib/preferences.lua`), so a key this page adds is kept without being declared a second time
there.

## The words

Two files, both required: `src/rfsuite/i18n/en.lua` and `de.lua`, under
`app.pages.settings_audio_events`. Add the row label, and any section header you introduced. The
page's own `help_message` lives beside it under `settings_audio_events_<page>` and has to be
updated in the same change — the page and its `?` button may not disagree.

Keys must be complete string literals. The precompiler cannot follow a key that is assembled at
runtime, and an unresolved key ships to the radio as a raw marker with nothing going red.

## The WAV file

Announcements play through `Audio.playEventFile(path)` or, inside the engine,
`tryPlayEventFile(audioState, now, path, opts)`. The path is relative to the pack root:
`evt/…`, `gov/…`, `adj/…`, `inflight/…`, `stat/alerts/…`.

`tryPlayEventFile` returns `true` when the file was handed to `playFile`, otherwise `false` and the
reason: `"cooldown"` (the quarter second after the previous file still runs), `"nofile"` (the pack
has no such file) or `"failed"` (`playFile` is missing or raised). An alert that repeats books its
announcement with `announcementDone(played, why)`: yes when it played, yes when the file is missing
-- nothing will ever play, and an unbooked alert would be tried again on every pass -- and no on a
cooldown or a failed hand-over, which are tried again on the next pass. Speak a trailing number only
when the file played. Keep the call in a tail position or in its own `local played, why = ...`;
behind `and` or in parentheses the reason is lost.

`resolveEventPath` looks for `/SOUNDS/rf/<language>/<path>` first and `/SOUNDS/<language>/<path>`
second, and caches the answer — including a miss, so a probe for a file that is not there costs
one open per session. That makes an optional file cheap:

```lua
local soundFile = "stat/alerts/notfull.wav"
if not resolveEventPath(soundFile) then
  soundFile = "stat/alerts/voltage.wav"   -- every pack has this one
end
```

Prefer that shape to assuming a file exists. A pack the pilot installed months ago will not have
the file your announcement was written against.

To speak a number after the file, use the radio's own teller — `playNumber(value, unit, attribute, volume)`
— rather than a spoken-number WAV. It follows the language set on the radio, which the pack does
not. Inside `lib/audio.lua` pass `audio_volume` as the fourth argument, and from outside it call
`Audio.playNumber(value, unit)`, so the number is spoken at the WAV volume level the file before it
plays at. A page that sounds one of the loose tones at the root of the pack (`/SOUNDS/rf/beep.wav`)
calls `Audio.playRawFile(path)`, which plays a full path at the same level.

**The file itself is generated, not recorded.** Add one entry to `bin/sound-generator/json/en.json`,
run `update-missing-translations.py`, fill in the other languages, and build. See
[`bin/sound-generator/README.md`](../../bin/sound-generator/README.md). Until a pack carries the
file, the announcement is silent — which is why the fallback shape above is worth using.

## What the packager ships

`bin/package/build_package.py` copies, per language, exactly these folders out of
`src/rfsuite/audio/<language>/`: `adj`, `app`, `evt`, `stat`, `gov`, `inflight` — into `SOUNDS/rf/<language>/`
on the card. For each locale it uses `default/` if present, otherwise the locale directory itself.
A new top-level folder needs an explicit packaging entry. The loose tones at the root of the audio
tree (`beep.wav`, `multibeep.wav`, `warn.wav`, `alarm.wav`) are copied into `SOUNDS/rf/`
separately; they are not part of the word lists and are not generated.

## A trap worth knowing before you audit anything

Several paths are **built by concatenation**, not written out: `"gov/" .. file` and
`"evt/" .. file` in `lib/audio.lua`, and `"inflight/fn/" .. id` and `"adj/" .. words[i]` in
`tasks/events/telemetry_bg/adjustments.lua`. A search for `"gov/active.wav"` finds nothing and
the file is used on every flight. Any sweep for unused audio has to account for the constructed
paths, or it will report two thirds of the pack as dead.

## Checklist

1. `lib/audio.lua` — the condition, a re-alert interval of 10 s, the state cleared in
   `Audio.resetConnectionState`.
2. Check both callers supply the telemetry field you read.
3. `category_page.lua` — one `CONFIG_SCHEMA` row and one `SECTIONS` item; the same default in
   `prefEnabled`.
4. `i18n/en.lua` and `i18n/de.lua` — the label, any new header, and the page's `help_message`.
5. `bin/sound-generator/json/*.json` — the line to speak; `--check` must come back clean.
6. `docs/audio/events.md` — the announcement, its switch, its default and what fires it.
7. `release-notes/<short-name>.feature.md` — the release note, filed under its release when it is cut (see `release-notes/README.md`).

The inflight overlay announces profile edges through `evt/profile.wav` and the existing number
teller only when the corresponding general PID/rate event is disabled. In flight, unread/unknown profiles use `inflight/paused.wav`; returning to read profiles uses
`inflight/resumed.wav` without an interlock cycle. Both cues are silent on the ground. These hooks share the Adjustments setting and critical-alarm gate.
