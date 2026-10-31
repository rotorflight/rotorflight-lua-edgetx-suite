---
title: Flight Log
sidebar_label: Flight Log
sidebar_position: 30
---

# Flight Log

A line per flight, written to the card when the craft disarms: when it flew, on which model, on
which pack, how long it was armed, and what the flight's telemetry reached. The page lists those
lines, newest first, and opens one to show the flight in full.

## Where to find it

*Tools* → *Flight Log*

The tile is locked while the model is armed (`lockedWhileArmed = true`), so the page cannot be
opened in flight. The page is always there, but nothing is written to the log until *Write a
flight log* is switched on in its own [*Settings*](#settings) tab.

From the dashboard widget at full screen the page can be opened directly: put *FLIGHT LOG* into
the [quick menu](../../dashboard/quick-menu.md) on *System* → *Settings* → *Dashboard* →
[*Quick Settings*](../settings/dashboard/quick_menu.md), or, on the Urban theme, set a key to
*Suite: Flight log*. Either opens the suite's tool inside the widget on this page, under the same
condition, and the back key on the page closes the tool again rather than stepping up to
*Tools*.

## Getting around the page

Four tabs across the top — *Flights*, *Models*, *Batteries*, *Settings* — and the tab of the view
on screen is drawn as the active one. A flight opened out of the list and a pack opened out of the
registry are not tabs of their own: they keep the tab they came from marked and carry a heading
naming what they show, the flight's date and time and the pack's name.

Back steps out of whatever was opened before it leaves the page: an open pack editor, then a
flight or a pack detail, then a filtered flight list, then the page itself.

## Flights

![The Flights tab](../../images/tools/flight_log/flights.png)

The flights in the log, newest first, under a line with their number and their total armed time.
Each row shows the date and time the craft armed, the model and the pack, and how long it was
armed. A log longer than the screen is paged with *Prev* and *Next*.

The `>` button opens the flight. Its heading is the flight's date and time; below it are the
model, the pack, the duration and, where the line carries them, the flight's statistics (see
[What a line holds](#what-a-line-holds)). A flight recorded without statistics says so instead.

![One flight opened](../../images/tools/flight_log/flight-detail.png)

## Models

![The Models tab](../../images/tools/flight_log/models.png)

One row per model name the log holds, with its number of flights and their total armed time. The
`>` button opens the *Flights* list with only that model's flights, headed by the model's name,
its number of flights and its total time.

## Settings

*Write a flight log* is what switches the log on. The other tabs only read what has been
written.

| Setting | What it does |
| --- | --- |
| Write a flight log | Off by default. While it is off nothing is written, and this page stays empty. While it is on, the dashboard widget also asks which pack is on the craft after connecting (see *The prompt on connect* below). |
| Minimum flight length | An arm shorter than this is a spool-up check rather than a flight, and is not logged. 30 s by default; 0 logs every arm. |
| Set the pack's battery profile | Off by default. A pack picked on the dashboard — in the prompt after connecting or under *BATTERY* in its quick menu — also moves the flight controller onto that pack's battery profile. Never writes while the model is armed. |

![The Settings tab](../../images/tools/flight_log/settings.png)

## Batteries

![The Batteries tab](../../images/tools/flight_log/batteries.png)

The registry of packs and the editor for it.

Which pack is on the craft is not chosen on this page but on the dashboard widget: in the
[prompt after connecting](#the-prompt-on-connect), or under *BATTERY* in its
[quick menu](../../dashboard/quick-menu.md). The choice is kept for this model, so the same pack
is marked again the next time the craft is connected; the flight's line records it, and a pack's
first flight of a session counts one cycle against it. Without the dashboard widget there is no
way to pick a pack: the model's flights are then logged against the pack last chosen for it, or
with the battery column empty where none ever was.

*New battery* opens the editor, which takes the whole screen until *Save* or *Cancel* — the tabs
are not drawn while it is open, because one press on a tab would discard what has been typed.
Back cancels it. A pack already in the list is opened with the `>` button, which shows what it
holds together with how many logged flights name it and when it was last used, and offers *Edit*
and *Delete*. Deleting asks first.

![The pack editor, scrolled to its models](../../images/tools/flight_log/pack-editor.png)

| Field | What it holds |
| --- | --- |
| Id | The name the flight's line and the model's own choice refer to the pack by. Letters, digits, `_` and `-`; anything else is dropped. It has to be unique in the registry; a new pack is offered the lowest positive number used by neither the registry nor any logged flight. |
| Name | What the pack is called on the page and in the flight list. Up to 24 characters. |
| Capacity | The pack's capacity in whole mAh, as on the Battery page. `0` means it is not recorded and the field is left out of the file. |
| Cells | The pack's cell count, 1 to 24. Only used to find the pack's battery profile on a flight controller that keeps a cell count per profile (see *The battery profile* below). `0` means it is not recorded and the field is left out of the file. |
| Battery profile | The flight controller's battery profile this pack belongs to, 1 to 6. `0` means none is recorded and the field is left out of the file. |
| Cycles | How many charges the pack has seen. It is counted up by flying, and is editable here for a pack that was already in use before it was entered. |
| Models | The craft this pack is offered for. The models are listed at the end of the form, below *Cycles*. *All models* (the default) offers it for every model; otherwise only for the models switched on. The list holds every model the radio knows of: those with logged flights, the connected craft, and every flight controller [whose name is recorded on the card](../../reference/configuration-files.md). A model never connected or flown here is not listed yet. A name containing a comma or a semicolon is not listed because the file uses both as separators. An older entry naming a model the radio does not know is kept and shown switched on. |

A new pack's suggested id skips every id that a flight read from the log still names, so it does
not reuse a deleted pack's id; a flight in a part of the log the card fails to read is not counted.
The editor becomes available once the flight log has finished loading. Typing a deleted pack's
id by hand is allowed when creating a pack or changing its id: saving shows a notice with the
number of its logged flights that now count under this pack, including in the flight list and
the pack's flight count.

Renaming a pack's id, or deleting it, takes the pack chosen for the connected model with it: the
choice follows the new id, or is cleared.

## The prompt on connect

While *Write a flight log* is on, the dashboard widget asks which pack is on the craft once the
connect sequence has finished. The packs offered are this model's entries in the registry under
*Batteries* — an entry with no model list is offered for every craft. Where the registry has no
pack for this model, nothing is asked. With the log off, the prompt does not appear; *BATTERY*
in the quick menu still lists this model's packs.

It appears **in fullscreen only**. A widget on the main screen receives no touch, so there is no
way for it to take an answer there; the prompt is what fullscreen shows instead of the quick
settings menu. It is offered **once per connection**: a pick, or closing it with the box in its
corner, leaves fullscreen, and the quick menu is what fullscreen shows the next time it is
entered, with a *BATTERY* button that brings the picker back. With a dashboard theme that takes
fullscreen for itself, the picker opens over that theme instead, and a pick or the box puts the
theme back rather than leaving fullscreen. Arming ends an unanswered prompt as well: fullscreen during
the flight and after it shows what it would without the prompt, and *BATTERY* brings the picker
back once the model is disarmed. No pack is recorded from the picker while the model is armed:
*BATTERY* is not listed then, and a pick that still arrives is refused and logged. Unplugging the
pack and plugging in another is a new
connection, so the question is asked again. The quick menu itself is described on
[its own page](../../dashboard/quick-menu.md).

*NO BATTERY* is an answer like any other. It clears the choice, and the flight's line is written
with its battery column empty. It always has the bottom row of the picker to itself. The picker
the widget draws for a theme without one of its own shows as many packs as fit above it and no
more; the Urban, Grid and Deck themes draw their own picker, which scrolls.

### The battery profile

With *Set the pack's battery profile* on as well, a pick in the prompt also tells the flight
controller which of its six battery profiles this pack belongs to. Which one that is comes from
the registry entry and from nowhere else:

1. `profile=1` … `profile=6` on the entry — the pilot saying it outright — is used as it stands.
2. Otherwise the entry's `cap=` is matched against the capacities the flight controller publishes
   for its own six profiles, and an **exact** match selects that profile.
3. Where the flight controller keeps a cell count per profile, the entry's `cells=` has to equal
   that profile's own cell count as well. This is what tells a 6S and a 12S pack of the same
   capacity apart. A profile whose cell count is `0` (the flight controller then detects the
   count from the voltage when the pack is plugged in) names no count, so it is matched only by
   an entry without `cells=`; a `cells=` that agrees with no profile of that capacity matches
   none. On a board whose profiles are all left at `0`, leave *Cells* at `0` or use `profile=`.
4. Where the entry names no profile and no board profile matches, **nothing is written**. A
   guessed profile would move the next flight's low-voltage cut.
5. Where more than one board profile still matches — two profiles with the same capacity and an
   entry without `cells=`, or two with the same capacity and the same cell count — **nothing is
   written either**, and the log says which profiles tied. `profile=` on the entry settles it,
   and so does `cells=` where it equals the non-zero cell count of exactly one of them.

An invalid explicit `profile=` or a capacity that matches no board profile is refused and logged
even when its numeric value is too large for an integer. An explicit valid `profile=` still wins
outright and the capacity is then ignored, as in step 1.

Whether the flight controller keeps a cell count per profile is read off its battery
configuration reply: firmware that does sends the six cell counts after the six capacities.
Where the reply has no such block, the profiles share one cell count, `cells=` is not used, and
the first profile set to the pack's capacity is the one selected.

The write is `MSP_SET_BATTERY_PROFILE` followed by the EEPROM write that makes the board apply
and broadcast the change — the same pair the dashboard's *BATTERY PROFILE* buttons send. It is
**refused while the model is armed**, and it is skipped when the board reported that profile on
connecting and no profile has been written since — by a pick or by the *BATTERY PROFILE*
buttons. The log says which of those happened, under the tag `rfsuite.battery_pick`.

## What a line holds

The first five fields are always there: the date and time the craft armed, the model name, the pack
the flight was flown on, and the armed seconds.

A flight during which the telemetry link was lost is still one line, written at the disarm, when
the craft is still armed once the link is back: its start is when it armed, its armed seconds
include the gap, and it is logged against the pack it armed with, counted no more than it would
have been without the gap. Where
the craft disarmed while the link was gone, the radio never saw the disarm, so the flight has no
honest end and no line is written for it.

Everything after them is the flight's own statistics, taken from the record the suite keeps while
the craft is armed. A field that was never recorded is left empty, so a line may carry all of them,
some of them or none.

A column whose sensor the model does not have, such as ESC temperature, is left empty rather than 0.

| Column | What it is |
| --- | --- |
| `mah` | Capacity used, as the flight controller reported it, rounded down to whole mAh |
| `vcel_min`, `vcel_max` | Lowest and highest pack voltage, per cell |
| `curr_min`, `curr_max` | Lowest and highest current |
| `tesc_min`, `tesc_max` | Lowest and highest ESC temperature |
| `vbec_min`, `vbec_max` | Lowest and highest BEC voltage |
| `hs1_min` … `hs3_max` | Lowest and highest headspeed on PID profiles 1, 2 and 3 |
| `sags`, `sag_min` | How many times the pack sagged to the flight controller's minimum cell voltage, and the deepest per-cell voltage it reached |

Per-cell voltage needs a cell count, which comes from the flight controller's battery
configuration. On a model where that has not been read, the two per-cell columns stay empty rather
than being divided by a guess.

A sag is a dip to or below the flight controller's own *Min cell voltage*, counted once per dip:
the pack has to come back 0.05 V a cell above the line before the next one counts. A reading at or
below 1 V is the main power gone rather than a sag and is not counted. `sags` is `0` where the
pack was watched and nothing happened, and empty where it could not be watched at all — no cell
count, or no minimum cell voltage from the board. The statistics are sampled every 0.5 s, so a dip
shorter than that can fall between two samples.

The headspeed columns are taken only while the rotor is under power, so they are the band the
governor held rather than the band the spool-up passed through; a profile the flight was never
flown on leaves its pair empty. A flight controller with more than 256 kB of flash has six PID
profiles and this file has columns for three — a flight on profile 4, 5 or 6 leaves all three
pairs empty.

A flight that produced no statistics at all — telemetry gone for the whole armed window — is
written as the five-field line it has always been, rather than as a line of empty columns.

## Notes

The file is plain text, one flight per line, with a header naming every column. It is meant to be
opened on a computer as well as here; editing a line on the card changes what this page shows and
leaves the rest of the file alone.

The battery registry beside it is the same kind of file, one pack per line, and it is meant to be
kept by hand as readily as from the editor: an edit made here rewrites the one line it changes and
leaves comments, unknown fields and the rest of the file exactly as they were.

A pack can leave the registry without this page knowing which models had it chosen: deleted or
given a new id in the file itself, or on this page while another model is connected. So the pack a
flight is about to be logged against is looked up in the registry at the disarm first. Where no
pack carries that id any more, the flight's line is written with its battery column empty, no
cycle is counted, the log names the id at warning level, and the model's choice of that pack is
cleared, so its later flights are not logged against an id that names nothing. Where the link was
lost during the flight, the choice is cleared on the card at the next logged flight that ends with
the link up. A registry the card does not read whole is not judged: the flight is logged against
the chosen id as before.

A flight counts as logged only once the file on the card has grown by exactly the bytes its line
takes. Where the card will not say how large a file on it is, the flight is not written at all and
the log says which step refused, rather than a line being appended to a file whose contents cannot
be established. The registry is held to the same standard: a pack's cycle count and the edits made
under *Batteries* are refused, with a message on the screen, rather than rewriting the file from a
read that may have been cut short. A registry of the size a pilot keeps is unaffected either way.

A line the card took only part of -- a write that came up short, or power lost during it -- is not
repaired: it stays in the file as a line of its own, and the next flight's line starts on a new
line rather than running on from it. The page skips such a fragment where it ends before the
flight's duration, and otherwise shows it with whatever it holds.

A stretch of the file that runs on for more than 1025 bytes (1024 and a carriage return) without a
line end -- a damaged card block, or text pasted in without line breaks -- can be skipped up to the
next line end rather than gathered up whole, and the page goes on with the line after it. The file
is read 4 KiB at a time, and a line that long is skipped where more than 1025 bytes of it are in
hand and the next read still brings more of the file, and read as it is otherwise. A last line
without a line end is therefore read as before unless that much of it was already in hand at a
read that still brought more of it. A flight's own line is a few hundred bytes and never comes near
it.

*Documented against RFSuite 0.1.7.*
