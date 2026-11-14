---
title: Logs
sidebar_label: Logs
sidebar_position: 20
---

# Logs

Lists the telemetry logs EdgeTX has written to the SD card and shows, for the one you pick, a
summary of the flight and a graph of up to four of its columns.

## Where to find it

*System* → *Logs*

Always available. The page reads the SD card only and does not talk to the flight controller.

EdgeTX writes a telemetry log only when logging is switched on for the model, with a Special
Function *SD Logs*. Without it there is nothing for this page to list.

## The list

The page searches `/LOGS/`, `/LOGS/rfsuite/` and `/LOGS/rfsuite/telemetry/`, each at its top
level and one folder down, and lists every `.csv` file it finds there that is a telemetry log,
newest first. *View* opens the summary of that log. *Graph* beside it opens the log's plot
straight away: it reads only what the plot needs and not the summary, so for a long log the plot
is there sooner, most of all in the tool opened from the dashboard. Back from that plot returns to
the list.

While it searches, the page shows how many folder entries it has read and how many logs it has
found so far. It shows no bar: how many entries a folder holds is not known before they have
been read, and reading them is most of the search.

Opened from the dashboard, the tool runs inside the dashboard widget, and the radio lets a widget
do only a limited amount of work each time it draws. There the search, the reading of a log for
its summary and the drawing of its graph are done in smaller steps than in the tool started from
the radio's menu, so on a card with many logs, or for a long log, they take longer.
Putting the found logs in order is split up the same way, so a card with several hundred logs
is listed there too. Fitting the model and file names of the 25 logs on screen into their column
is split up as well, so the search notice stays up a moment after the search has ended, and after
*Previous* or *Next* a notice shows *Select Log File* with which logs it is preparing, out of how
many, before the list appears.

The list shows 25 logs at a time. Scroll it by touch, or turn the rotary encoder to step through
the logs' *View* and *Graph* buttons. Where there are more logs, *Previous* above the list and *Next*
below it show the 25 before or after, with which logs are shown out of how many beside them.
Coming back from a log's summary finds the list on the same 25.

The list is kept when you leave the page, so coming back shows it at once, on the 25 you left
it on. *Reload* in the header searches the card again and starts at the newest log; a log written
since the list was read appears only then. The tool holds on to only the last few pages you
opened, so after several other pages, or after leaving the tool, the page searches again.

A file whose name carries a date and a time, as EdgeTX names its logs
(`<model>-YYYY-MM-DD-HHMMSS.csv`), is listed without being opened. Any other `.csv` file is
opened, and is listed only if its first line begins with the `Date,Time` header EdgeTX writes;
a spreadsheet or another program's CSV file in the same folder is left out.

## The summary

While *View* reads the log, a bar shows how much of the file has been read so far. The plot's
own loading notice shows the same.

| Row | What it shows |
| --- | --- |
| Flight Time | The time from the first to the last row of the log, and the number of rows. |
| Voltage | The battery voltage at the start, the lowest with the sag from the start, and at the end. |
| Current | The peak and average current, and the consumption: the last capacity reading, or the average current over the flight time where the log has no capacity reading. |
| Headspeed | The highest headspeed, and the lowest above 1000 rpm, both only while the motor is driving the head (armed, and throttle at 25 % or more or current at 1.5 A or more). |
| ESC Temp | The highest and the starting ESC temperature, and the highest throttle. |

Each figure is read from the column whose header names it -- `Vbat(V)`, `Curr(A)`, `Capa(mAh)`,
`Hspd(rpm)`, `EscT(°C)`, `Thr(%)`, `ARM` and their usual variants. A plain `Thr` column is the
throttle stick channel, not the throttle the flight controller reports, and is not used. **A figure whose column the log does not have is
shown as `--`.** That is what a log from a model without Rotorflight telemetry usually shows for
most rows: its first columns are link statistics, and none of them is taken for a flight value.

A log without an `ARM` column gives the headspeed rows nothing to tell armed from disarmed by, so
they then rest on throttle and current alone.

A model can hold two sensors of the same name -- `Curr` and `Capa` from the native CRSF battery
frame beside the same names from the flight controller's custom telemetry, for example -- and
its log then has two columns of that name. EdgeTX writes the one it is not receiving as 0. The
summary reads the later of the two columns, and the graph's offered sets plot the same one; the
column chooser lists both. Where the figures read 0 although the flight drew current, the sensor
the radio receives is the earlier column: delete the sensors the model no longer receives on its
telemetry page, and the next log has one column of each name.

## The graph

*Graph*, on the summary or in the list, opens a plot of the log over time. Choose up to four
columns, one per *Curve*, or one of
the offered sets (*Power*, *Battery*, *Link*, *Governor*, whichever this log can serve), and
press *Show*. Each curve has a colour of its own: darker ones in the light colour scheme, brighter
ones in the dark. Zoom, page and a cursor readout work on the plotted flight; where the log holds
more than one flight, the chooser also offers which one.
A column chosen in more than one slot is plotted once.
*Show* with the curves already plotted keeps the plot as it is, zoom included. Back from the plot
to the summary keeps the log read, so *Graph* opens again without reading the file a second time;
only the curves are chosen again.
Paging a zoomed plot moves it by about half a window. Where the window on screen was read at the
screen's resolution, the part both windows share is kept and only the newly shown part is read;
at either end of the flight the window is read whole.
Whenever the plot reads the file -- its index when opened from the list, after *Show* with other curves
or another flight, and on a zoom or page step whose window has not been read yet -- the plot gives
way to the loading notice, with a bar for how far that read has got. A window the plot still holds
from an earlier read (it keeps the last few) is drawn again without the notice.

The plot's buttons:

| Button | What it does |
| --- | --- |
| `<` `>` | Step the cursor, the vertical line on the plot, a few pixels to the left or right -- the finest step the readout can tell apart. The time beside the buttons (from the start of the flight) and each curve's value at the cursor follow it. Only the cursor and those values change; the rest of the page is not built again. |
| `-` `+` | Zoom out or in around the cursor. |
| *Full* | Shows the whole flight again. |
| `<<` `>>` | Page a zoomed plot by about half a window. |
| *Sensors* | Back to the curve choice. |

A curve's value at the cursor is the highest reading the plot holds at that place, which covers
about one cursor step of the flight; `-` where the curve has no reading there.

Changing the curves while a plot is still being read is safe. If the tool reaches its
instruction limit in the middle of a change, the plot stays empty instead of the page failing
on every pass. Choose the curves again and press *Show* to draw it.

The graph needs the `Date` and `Time` columns and at least one row whose time it can read, written
the way EdgeTX writes it (`HH:MM:SS.mmm`). A file that lacks either says so instead of offering
columns: *Not an EdgeTX telemetry log* without the two columns, *No row carries a time the graph
can read* where no row's time has that form. The summary also reads a time without the
milliseconds, so such a file can have a summary and still no graph. A log without any data rows
has no summary, and the summary offers no *Graph* button. The list's *Graph* opens every listed
log; one without a row the graph can read then says *The log file carries no data rows*.

## Related

- [EdgeTX manual](https://manual.edgetx.org/) -- the *SD Logs* Special Function, which writes these files.

*Documented against RFSuite 0.1.7.*
