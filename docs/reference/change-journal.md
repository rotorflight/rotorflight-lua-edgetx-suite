---
title: Change journal
sidebar_label: Change journal
---

# Change journal

The suite keeps a small record of values written to a flight controller, one file per board:

`/SCRIPTS/RFSUITE/user/journal/<mcu id>.lua`

The board ID uses the same filename filter as the per-model preferences: characters other than letters,
digits, underscores and hyphens become underscores. The Tune Advisor is the only writer for now. It appends
one line per changed value after the flight controller acknowledges the EEPROM commit.

## The lines

Each line is one Lua statement:

```lua
e(1792756800,"tune_advisor",1,"pid_0_F",100,80)
```

| Position | Meaning |
| --- | --- |
| time | Unix seconds from the radio clock, or 0 if neither clock interface is available. |
| source | The feature that wrote the value, currently `tune_advisor`. |
| profile | The 1-based PID profile for PID gains and I-term relax cut-off fields; the 1-based rate profile for rate fields. |
| field | The MSP codec's field name, for example `pid_0_F` for Roll FF or `rcRates_2` for Pitch RC rate. |
| old | The raw integer value read before the write. |
| new | The raw integer value written. |

Strings are quoted Lua strings; source and field names contain only letters, digits, underscores and dots.
Numbers are integers. The values are raw MSP values, so rate values may use different units from the page.

## Time and order

The time is `getRtcTime()` on radios that offer it. Otherwise the suite computes Unix seconds from the
`getDateTime()` calendar, using integer arithmetic; without either interface it records 0. Signed 32-bit
Unix seconds reach their limit on 19 January 2038. A calendar time outside the supported range records 0.

The clock is the radio's own and is only as right as that clock. Correct it on the radio if needed. Lines
always stay in the order appended, even if the clock is wrong or is set back between saves. The Tune Advisor's
saved flights (`tune/<mcu id>.lua`) carry their time from the same clock, so a flight and a change applied after
it can be put in order.

## Reading it

A reader reads the text and compiles it with Lua's
`load(text, name, "t", { e = collector })`, where `collector(time, source, profile, field, old, new)` receives
each line. Use `load`, not `loadScript`: on EdgeTX, `loadScript` does not pass its environment argument to
the chunk. The suite itself reads the text a few lines at a time, one group per pass of the page, so that a long
journal never holds up the radio.

The Tune Advisor page reads the journal when it opens, to find the P, FF and rate values you last set yourself:
for each, it follows its own entries back from the current value -- P and FF on an axis and PID profile, the rates
on a row and rate profile -- and stops at any other change. It folds the entries as it reads them and keeps none.
If the file is there but cannot be read -- it does not open, for example -- the page raises no P and changes no
FF until it can be read again.

## Starting afresh

The journal does not grow without limit. When a save leaves it above 16 KiB, about 350 changes, the Tune Advisor
page starts it afresh on the passes after the save; if the page is left before then, it does so the next time the
page opens, before the journal is read. A journal from an earlier version that is already larger is started afresh
the same way on the first opening, which then takes a few seconds longer: it is read a few lines per pass.

The new journal keeps what the page needs and nothing else. For every profile and field, the Tune Advisor's newest
unbroken run of its own changes -- each starting at the value the one before it ended at, with no other change on
that profile and field after it -- becomes one line, from the value the run started at to the value it ended at,
with the time of its last change:

```lua
e(1792756800,"tune_advisor",1,"pid_0_P",50,70)
```

Runs that came back to their starting value are left out, as are all other lines. So the value each run started
at -- the one you set yourself -- and the limits around it stay the same however many saves lie between. A
step-by-step history of every change is not kept.

The journal before it is kept beside it as `<mcu id>.lua.bak`: the one earlier generation on the card. The next
start afresh replaces it. The new journal is written beside the old one and checked before it takes its place, so
a start afresh that is cut short -- the radio switched off, a full card -- leaves the old journal whole. If only
the `.bak` stands, the Tune Advisor page puts it back under its own name when it opens, and starts it afresh then
if it is above 16 KiB; a save does the same before it appends. To delete the journal by hand, delete both files.

A journal that could not be started afresh is tried again after the next save or opening; meanwhile its newest
16 KiB are read: from the first whole line in that part to the end.

## Reading and repairing

Apart from starting afresh, the suite only appends to the file. Each append is checked against the file's growth
on the card. A failed journal append is reported by the Tune Advisor and does not undo the board's EEPROM commit.

When a group of lines does not compile or run -- a half-written last line, or a line broken by hand -- the
reader reads that group again line by line and skips only the lines that do not read; every other line still counts.
A later append starts on a new line and leaves the broken fragment in place, where it is skipped again until the
journal starts afresh, which leaves it out. A file above 16 KiB is read from its newest 16 KiB; a line cut in two
by the start of that part is not read. A single line of more than 8 KiB is not one the suite wrote: a journal
holding one is not started afresh until it is removed by hand.

There is no journal viewer or undo button in the UI. This is a record for undoing a change by hand: select
the recorded profile and put the old value back on the appropriate settings page, then save it.

## Related

- [Tune Advisor](../pages/flight_tuning/tune_advisor.md)
- [Configuration files](configuration-files.md)
