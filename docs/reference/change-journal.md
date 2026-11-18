---
title: Change journal
sidebar_label: Change journal
---

# Change journal

The suite keeps a small, append-only record of values written to a flight controller, one file per board:

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

The append-only file grows without limit. The suite reads at most its newest 64 KiB, some 1400 entries: from
the first whole line in that part to the end, with older lines left in the file but not read. The Tune Advisor
follows the journal back from its newest entries, so a journal past 64 KiB keeps working; archive it by hand only
if you want a smaller file.

The Tune Advisor page reads the journal when it opens, to find the P you last set yourself: it follows its own
entries for P on an axis and PID profile back from the current value and stops at any other change. If its own
changes go back further than the newest 64 KiB, the oldest value read counts as yours, and the current P when
none of them is read: after that many changes the page's limit of 50 % above your own P counts from that value,
not from the P you set before them. If the file is there but cannot be read -- it does not open, for example --
the page raises no P until it can be read again.

## Reading and repairing

The file is never rewritten by the suite. Each append is checked against the file's growth on the card.
A failed journal append is reported by the Tune Advisor and does not undo the board's EEPROM commit.

When a group of lines does not compile or run -- a half-written last line, or a line broken by hand -- the
reader reads that group again line by line and skips only the lines that do not read; every other line still counts.
A later append starts on a new line and leaves the broken fragment in place, where it is skipped again; delete
it by hand to tidy the file. A file above 64 KiB is read from its newest 64 KiB; a line cut in two by the start
of that part is not read.

There is no journal viewer or undo button in the UI. This is a record for undoing a change by hand: select
the recorded profile and put the old value back on the appropriate settings page, then save it.

## Related

- [Tune Advisor](../pages/flight_tuning/tune_advisor.md)
- [Configuration files](configuration-files.md)
