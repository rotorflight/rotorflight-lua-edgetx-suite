---
title: Settings
sidebar_label: Settings
sidebar_position: 40
---

# Settings

The suite's logging and diagnostics switches: how much it logs, where the log goes, how many
power-ups of the radio keep their log files, and whether the configuration tool shows its own
memory use. These are the settings a report is
usually asked for with; [Collecting logs for a report](../../troubleshooting/collecting-logs.md)
says what to set and which files to attach.

## Where to find it

*System* → *Developer* → *Settings*

Not listed at all until *Developer Tools* is switched on under *System* → *Settings* →
*General*.

## Settings

| Setting | What it does |
| --- | --- |
| Log Level | How much is logged: *OFF*, *ERROR*, *WARN*, *INFO*, *DEBUG* or *TRACE*, default *OFF*; [what each level adds](../../troubleshooting/collecting-logs.md#what-each-level-adds) is listed with examples. Errors, warnings and the info lines that mark milestones are logged at every level, *OFF* included: they go to the in-memory list under *Session Logs* and, with *Log Session To Card* on, to the card. The level decides what is added on top: *INFO* adds the info lines of in-flight tuning and a few other parts that ask for it first, *DEBUG* the steps in between, *TRACE* also every request to and reply from the flight controller, with its bytes. The log lines printed to the radio's debug output or sent to the serial port appear only once the level is raised to them. Called *Debug Level* in earlier releases. |
| Show Header Memory | Shows the configuration tool's Lua memory, `LUA: <n>KB`, in the page header. Off by default. |
| Enable Serial Debug | Also sends every log line the log level lets through to the radio's serial port. At *OFF* that is none. Off by default. |
| Log Session To Card | Writes the log to `/SCRIPTS/RFSUITE/user/logs/` on the card, one set of files per power-up of the radio, named after the moment it was switched on. Off by default. On its own it already writes the dashboard's and the configuration tool's files with errors, warnings and info, a state line with the memory figures every five seconds among them; the background decoder's files also need the log level at *DEBUG* or above. |
| Keep Logs Of | How many power-ups of the radio keep their log files on the card, 1 to 50, default 10. When the radio is next switched on with logging on, the files of older power-ups are deleted; files an older release wrote are left alone. |

Nothing changes until *Save* in the header is pressed.

## Related

- [Collecting logs for a report](../../troubleshooting/collecting-logs.md) — the files on the card
  and which of them to attach.
- [Session Logs](../tools/diagnostics/session_logs.md) — the in-memory list.

*Documented against RFSuite 0.2.2.*
