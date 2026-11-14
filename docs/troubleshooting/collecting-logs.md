---
title: Collecting logs for a report
sidebar_label: Collecting logs
---

# Collecting logs for a report

The suite keeps its log in memory and shows it under *System* → *Tools* → *Diagnostics* →
*Session Logs*. That ring belongs to the script that holds it, so it is gone the moment that
script stops — which is exactly the case a report is usually about. Writing the log to the card
is what survives it.

## Switching it on

*System* → *Settings* → *General* → **Developer Tools**, which makes the *Developer* tile
appear, and then *System* → *Developer* → *Settings*:

| Setting | What to set it to |
| --- | --- |
| **Log Level** | *INFO* for a first report. *DEBUG* for a problem that needs the steps in between, and it is also the level from which the background decoder keeps a record of its own. *TRACE* only when asked — among other lines it adds every request to and reply from the flight controller, with its bytes. |
| **Log Session To Card** | On. Nothing is written to the card while this is off, whatever the log level says. |
| **Keep Logs Of** | How many power-ups of the radio keep their files, default 10. Raise it if a problem is often noticed only days later. |

**Log Session To Card is the switch that decides whether anything is written.** With it on and
the log level left at *OFF*, the configuration tool and the widgets already write their files:
errors, warnings and the info lines that mark milestones — the connect sequence and the state line
below among them — are kept whatever the level says. **The log level decides how much more goes
in** ([what each level adds](#what-each-level-adds)). The background decoder's files are the
exception that needs both, because the decoder only starts writing at *DEBUG* or higher.

Switch both back off once the report is sent. The card write is small but it is permanent, and
a raised log level adds work to every pass that writes a line -- *TRACE* writes in most passes,
*DEBUG* in fewer. That work comes on top of the dashboard's heaviest moments, such as the passes
right after a disarm, when the flight is logged and the post-flight screen is loaded.

## What each level adds

The levels are cumulative: each one writes everything the level above it in the table writes, and
adds its own row. The examples are the message part of a line; long ones are cut short with `…`.

| Level | What it adds | Example lines |
| --- | --- | --- |
| *OFF* | **The base log, written at every level.** Errors, warnings, and the info lines that mark milestones: the connect sequence, the configuration tool being opened and closed, a save to the flight controller, a flight being logged. With *Log Session To Card* on, also the state line every five seconds, the dashboard's milestones with the memory figures, and any fault the suite caught. All of it goes to *Session Logs* and, with *Log Session To Card* on, to the card. Nothing goes to the radio's debug output or to the serial port. | `MSP runtime initialized via …`, `MSP link connected`, `FBL connected and telemetry initialized`, `tool opened, lua … kB, free … kB`, `start page=… steps=… reboot=… client=…`, `flight logged: …s, battery=…`, `max retries cmd=… rw=R client=… attempts=…`, `low heap: free_kb=…` |
| *ERROR* | Nothing on the card or in *Session Logs*. Error lines start to appear on the radio's debug output and, with *Enable Serial Debug* on, on the serial port. | `tool not opened: …`, `MSP queue module unavailable`, `playNumber error: …` |
| *WARN* | Nothing on the card or in *Session Logs*. Warnings join the errors on the debug output and the serial port. | `refused reason=armed page=…`, `queue cleared client=… keepWrites=… …`, `UID read failed (cmd=160); backoff …s` |
| *INFO* | Info lines on the debug output and the serial port. And the info lines of the parts that ask for *INFO* before they write, which are not in the base log: the in-flight tuning surface (its phase changes with the memory figures, the interlock, every global variable it writes, reading the board), with *Log Session To Card* off, the dashboard's milestones (created, a phase change, a theme loaded or released, the link lost) with the memory figures, the configuration tool's closing sequence, and the raw telemetry configuration read from the flight controller. The state lines also reach *Session Logs* with *Log Session To Card* off. | `phase … -> …, lua … kB, free … kB`, `interlock on: bank ch… value ch…`, `prime done: … value(s) cached, … id(s) unanswered`, `theme … loaded for phase … (…, from …), lua … kB, free … kB`, `Closing sequence started (Tick 0).`, `parsed slots: …` |
| *DEBUG* | The steps in between, from every part of the suite. The dashboard reloading its settings and building a screen, with what the build cost, a long pass and the work it was, a view opening or closing, what the connect screen waits for, each connect task's time. A request to the flight controller that has to be sent again. Every page change in the configuration tool, with the memory figures. The background decoder's own files, and the signal from the dashboard that the decoder watches for the *dashboard widget silent* line. The telemetry decoder: which part of the suite starts, resumes, stands aside or takes the decoding over, a frame the link lost, a decoder module that did not load. The adjustment announcement: each adjustment the flight controller reports, and whether it was spoken, or why not, including one that waits while an in-flight tuning selection is being spoken. | `dash: takes over decoding: no other decoder seen for 1.0 s`, `bg: frame gap: id … -> …, … missing, … gap(s) counted`, `dash: report: function … value …`, `dash: function … value … not spoken: a profile announcement says it`, `page … -> …, lua … kB, free … kB`, `scene built: … pass(es), … objects, lua … -> … kB`, `long pass: …% of the instruction budget, work …`, `LVGL BUILD SUCCESS: themePath=…, #children=…`, `completed task … in … s, lua … kB`, `tx cmd=… rw=R client=… attempt=2/… len=…`, `phase … -> … after …s page=…`, `load begin steps=… overlay=…`, `dashboard widget silent 3.0 s, last pass 56 %` |
| *TRACE* | Every request to and reply from the flight controller, with its bytes, and whether a reply came from the link or from the cache. The service widget's instruction budget every five seconds. On the dashboard, each telemetry read, the screen key that moved and each build starting. Each telemetry frame decoded, with the values in it that changed (a group of values, such as the cells or the attitude, by its name), and what the adjustment announcement is waiting for. | `dash: frame …: … value(s), changed: Hspd=… Vbat=…`, `dash: waiting: function … value … settles in … s`, `queued cmd=… rw=R client=… from=… depth=…`, `tx cmd=… rw=R client=… attempt=1/… len=… <bytes>`, `rx cmd=… src=wire len=… client=… attempt=1 dt=… err=… <bytes>`, `rx cmd=… src=cache …`, `telemetry read, phase …`, `render key … -> …`, `scene started, lua … kB` |

***OFF* adds nothing extra; it is not silence.** It is the shipped setting, and a radio left at it
still keeps errors, warnings and the milestone lines in *Session Logs*, and on the card once
*Log Session To Card* is on. What *OFF* leaves out is everything the rows below it add. *ERROR* and
*WARN* change only what reaches the radio's debug output and the serial port; for a log on the
card, the first level that adds lines is *INFO*.

## Where the files land

`/SCRIPTS/RFSUITE/user/logs/`. **Every file of one power-up of the radio starts with the
date and time the radio was switched on**, so the files that belong together sort next to each
other:

```
2026-10-29_10-15-03_dashboard.log
2026-10-29_10-15-03_dashboard.step
2026-10-29_10-15-03_function.log
2026-10-29_10-15-03_function.step
2026-10-29_10-15-03_tool.log
2026-10-29_10-15-03_tool.step
2026-10-29_14-02-41_dashboard.log
...
```

The part after the time says which part of the suite wrote it:

| Name | Written by |
| --- | --- |
| `dashboard` | The dashboard widget and the service widget, which share a script — and the configuration tool when it is opened from the dashboard, which runs in that same script. |
| `tool` | The configuration tool started from the radio's *Tools* menu. Opening it again during the same power-up adds to the same file, under a header line of its own. |
| `function` | The background decoder special function, if the model runs it and the log level is *DEBUG* or *TRACE*. |

Each of them writes **two files**, and they answer different questions:

- **`.log`** — the log itself. It is written every few seconds, so the last few seconds before a
  freeze can be missing from it.
- **`.step`** — one line, saying the last thing that was started and how much Lua memory was in
  use at that moment. It is rewritten and closed on the spot, so it is there even when the radio
  stopped without warning. Its timestamp is how far that part of the suite got.

The files of the last 10 power-ups are kept (*Keep Logs Of*); when the radio is switched on the
next time with logging on, the oldest are deleted. Only files named this way are touched. Files
an older release wrote — `widget_1.log`, `tool_seq.txt`, `function_step.txt` and the like — are
left where they are; delete them by hand once they are no longer needed.

A radio whose clock was never set names its files after the date its clock shows. They still sort
in the order the radio was switched on, as long as the clock runs.

## Reading the files together

**All files of one power-up share one clock.** The number at the start of every line is the time
in seconds since the radio was switched on, the same in every file, so the lines of the dashboard,
the tool and the background decoder can be read side by side in the order they happened.

**The first line of every session names what wrote it**: the part of the suite, the power-up it
belongs to, the date and time the session started, the radio, the screen size, the EdgeTX
version, the suite version, the build and the language. *build* changes with every change to the
installed files, so two installations of the same version can be told apart by it.

**Every five seconds each part of the suite writes a state line** at *INFO*:

```
state: instruction budget 12% now, 41% peak/5s, 97% peak since load, 58 objects, lua 1293 kB, free 1933 kB, cpu 38%, ui 30 fps / 21%, peak work scene, lua peak 1410 kB, theme=system/grid, decoder dash, 40 frames, 0 gaps
```

| Field | Meaning |
| --- | --- |
| `instruction budget` | The dashboard only: how much of its share of a cycle the dashboard used. |
| `lua` | The Lua memory of the part of the suite that wrote the line. The dashboard, the tool started from the *Tools* menu and the background decoder each count their own. |
| `free` | What the radio has left for every script and most of its own work. `-` where the radio does not report it. |
| `cpu` | How busy the radio's processor was. EdgeTX 2.12.5 and later only. |
| `ui` | The screen's frame rate and the share of time spent drawing it. EdgeTX 2.12.5 and later, colour radios only. |
| `peak work` | The dashboard only: what it was doing in the pass that cost the most in these five seconds, the word from the dashboard's `.step`, or `state` for an ordinary pass. |
| `decoder` | Who decoded the flight controller's telemetry in the part of the suite that wrote the line, since its last state line: `decoder dash, 40 frames, 0 gaps` names that part (`dash` the dashboard's script, `bg` the background decoder, `tool` the tool started from the *Tools* menu) with the frames it took and the gaps it counted in them; `decoder elsewhere` says it stood aside because another part was decoding; `decoder idle` that nothing arrived, and `decoder -` that the decoder had not loaded yet. In the dashboard's, the background decoder's and the tool's line, at its end. *Session Logs* cuts a line at 100 characters, which leaves the field off the dashboard's line and off a tool line with `cpu` and `ui` or a long page name; there it is read on the card or the serial port. |
| `lua peak` | The dashboard only: the highest `lua` figure sampled since it loaded. It is sampled at this line and, from *DEBUG* up, around each screen build, so a shorter peak between them is not seen. |

The same memory figures are added to the lines that mark the configuration tool being opened and
closed, the in-flight tuning surface changing phase or closing — from *INFO* up — and, at *DEBUG*,
every page change in the tool. Two such lines around a visit say what that visit kept.

## Reading a dashboard log

Every line starts with the part of the suite that wrote it, its tag, then its level:

| Tag | What it says |
| --- | --- |
| `rfsuite.widget` | The dashboard itself: created, each phase, connected, link lost, on or off screen, the state line, long passes, a stop at the instruction limit. |
| `rfsuite.widget.theme` | Which theme was loaded for which phase, why and from which one; a theme that did not load; themes released. |
| `rfsuite.widget.job` | Each screen build: how many passes, how many objects at the top of the screen (counted as the state line counts them, so an object inside another is not), Lua memory before and after. |
| `rfsuite.widget.standby`, `.splash` | The standby screen, and what the connect screen is waiting for. |
| `rfsuite.widget.view`, `.menu`, `.roll` | Full-screen views opening and closing, each press, a write the menu queued, the rolling menu. |
| `rfsuite.widget.tool` | The steps of opening and closing the tool inside the dashboard. |
| `rfsuite.widget.object` | An object type that loaded, or did not, for the boxes of a theme. |
| `rfsuite.reload` | The dashboard reloading its settings, and why it waited. |
| `rfsuite.events`, `rfsuite.tasks.…` | The connect sequence and the arm and disarm tasks, each with its time and memory. |
| `rfsuite.sensors` | Which telemetry source was taken, or, while connected, that none was found; once per connection. At *DEBUG*, once per value, that it is read from the decoder of the part of the suite that decodes (`voltage read from the decoder (Vbat)`). |
| `rfsuite.decoder` | The telemetry decoder. Each line starts with the part of the suite that decodes: `dash`, `bg` (the background decoder) or `tool`, because all three can decode and write to the same serial port. |
| `rfsuite.adjust` | The adjustment announcement: what the flight controller reported, and whether it was spoken. Named like the decoder's lines. |
| `rfsuite.audio`, `rfsuite.inflight` | Announcements, and the in-flight tuning surface. |
| `rfsuite.require` | A module that did not load and, at *DEBUG*, a few seconds after the dashboard starts, each module loaded with the Lua memory before and after it, and each released one by one; closing the tool says how many it dropped. A module that loads others carries their memory in its figure. |

**What is using the resources.** At *INFO*, the state line every five seconds says how much of the
budget the dashboard used and on what, and the milestones carry the memory figures. Compare a figure
before and after a theme, a tool visit or a connect. At *DEBUG*, `long pass` names the pass that
raised the five-second peak, from half the budget up, and each `… built:` line says what one screen cost.

**Where a problem began.** Look for the first `error` or `warn` line, then read the lines before it
at the level you recorded. A phase line, a theme line or `waiting:` says what the dashboard was doing.
At *TRACE* over the serial port the same stretch shows each read and each build starting.

**Which part of the suite writes what.** The lines that follow the dashboard's own five-second report
(each module loaded or released, a view, a press, a tool step, the armed edge, a phase, the link lost)
come from the Lua state the dashboard runs in, and a level changed on the radio reaches them within
five seconds of the dashboard taking the new settings. It takes them while it is on screen, not
while the model is armed, and after a flight not before the link is back; until then they keep the
level they had. The tool started from the *Tools* menu and the background decoder have lines of their own.

**What a level costs.** With the log off, the dashboard builds none of these lines but its errors,
warnings and base milestones. *TRACE* writes lines every second and adds to what it measures, so
compare budget figures only between logs taken at the same level.

## The two lines worth reading first

**The dashboard's `.step` says what the dashboard was doing.** While the suite connects it names
the task it is on; afterwards it names the class of work of the last screen it built — *splash*,
*scene*, *menu* or one of the tuning surfaces. So a radio found stopped tells you which of those
it was in the middle of.

**The background decoder's `.step` says whether the dashboard is still running at all**, which is
the one thing the dashboard cannot say about itself. When a widget uses more than its share of a
cycle the radio stops calling it, and it cannot write down that this happened to it. The
background decoder runs outside the widgets and keeps watching, so its line reads:

```
dashboard widget silent 3.0 s, last pass 56 %
```

The percentage is what the dashboard's last cycle cost, out of what it is allowed. Near or above
100 is the reading that explains a dashboard that stopped drawing.

A dashboard on another screen page, or behind one of the radio's menu pages, is not reported: the
radio keeps calling it there, and it keeps doing its work. Off screen, the percentage is that of the
last cycle in which it was drawn, or 0 if it has not been drawn yet, so a low figure after a stop
off screen says nothing about what the dashboard's last cycle there cost.

The dashboard's `.step` needs nothing but *Log Session To Card*. The background decoder's also
needs the decoder on the model and the log level at *DEBUG* or above.

## What to attach

Take the card out and copy the whole `logs` folder. If that is too much, the useful minimum is:

- Every file of the power-up in which the problem happened — the ones whose names start with the
  same date and time.
- What you did, in the order you did it, and what the screen showed.

## Notes

- **A file that is not there is an answer too.** No `function` file means either that the log
  level was below *DEBUG* or that the background decoder was not running on that model — see
  [the background decoder](../reference/background-decoder.md). No `dashboard` file after a
  session with the dashboard on screen means the widget never got as far as writing one.
- **A stop at the instruction limit is written only where something catches it.** One that reaches
  the dashboard's own drawing and background calls gives the `.log` a `widget.refresh stopped: …`
  line (or `.background`, `.update`) and an `rfsuite.fault` line, and the `.step` file the fault.
  One caught further in, while a theme loads for example, is that part's own warning or error.
  Where the radio stops the widget outside them, the widget cannot write that this happened, so
  the last thing in its `.log` is the approach to the fault. The background decoder's files are not affected: its script is paused and
  resumed rather than cut off.
- **Opening the configuration tool pauses the background decoder** for as long as the tool is
  open, so a gap in the `function` file over that stretch is expected.
- **A session stops writing at 5000 lines** and says so on its last line, rather than dropping its
  middle. At *DEBUG* that takes a long session: the connect sequence writes a few hundred lines,
  and after it a file grows by two lines or more for each request a page sends to the flight
  controller, and by a line or two every five seconds while the dashboard shows a disarmed model.
  *TRACE* adds a line for each telemetry read the dashboard makes, two a second while it reads, so
  a session at *TRACE* with the dashboard connected reaches the cap in about forty minutes. Nothing is added to it after that, a
  fault included: a fault after the cap goes only to the `.step` file, where it stays until the
  next step replaces it. Turning *Log Session To Card* off and on again starts a new session in
  the same file.
