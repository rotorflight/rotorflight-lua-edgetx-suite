---
title: Background telemetry decoder
sidebar_label: Background decoder
---

# Background telemetry decoder

Rotorflight sends its own telemetry values in a custom frame that EdgeTX does not decode by
itself, so something on the radio has to unpack it and hand the values to the sensors. The
dashboard does that on its own, in the widget, and it works — but a widget call is stopped at a
fixed instruction count, so when frames arrive faster than the widget can decode them the older
part of the backlog is dropped.

The suite can move that work into a small script the radio runs outside the widgets:
`SCRIPTS/FUNCTIONS/rfsbg.lua`. A call there is paused and continued on the next turn instead of
being cut off, so it decodes every frame it takes. The same script also makes the adjustment
announcements, at the level set under *Settings* → *Audio* → *Volume*, while *Adjustment events* is
on (*System* → *Settings* → *Audio* → *Events*). It takes them from the frames it decodes, and with the setting
off it does not load the part that speaks them at all; switched on in the tool, it picks the change
up with its next reading of the settings.

## Where to find it

*Model* → *Special Functions*, as an entry named `rfsbg` on the always-on switch.

The suite adds that entry itself, once, the first time a model connects to a flight controller.
It takes effect the next time the model is loaded, because the radio reads a model's special
functions when it loads it. Nothing is asked of you and there is nothing to confirm.

## Turning it off

Untick the entry on the *Special Functions* page. The suite leaves an entry it can see alone,
ticked or not, so it stays off.

Deleting the entry instead frees the script slot, and the suite adds it again on the next
connect — deleting is not how to switch it off.

Without the script, the dashboard decodes for itself exactly as it did before. Nothing is lost
and nothing needs to be configured. While the dashboard's connect sequence is still reading the
flight controller's configuration, it decodes only the armed state (the arming flags, or the
System Status word), so it can see the model arm and stop sending to it; the other values follow
once the sequence is through. That is also what
happens on the first connect of a model, before the radio has loaded the entry the suite has
just added.

## Notes

- **The radio has only a handful of script slots** — seven or nine, shared by every mixer and
  special-function script on it. This takes one of them.
- **A model that already runs another background decoder does not get this one.** Rotorflight's
  earlier Lua scripts install `rf2bg`, which reads the same frames. Every special-function
  script on a radio shares one telemetry queue, so whichever runs first takes the frames and a
  second decoder receives nothing at all. Where the suite sees such an entry on the model it
  installs nothing and writes the reason to the log; the dashboard then decodes for itself.
- **Opening a tool pauses it**, together with every other permanent script, for as long as the
  tool is open. Whoever is running then decodes for itself: the dashboard notices within a
  second and takes the decoding back, and the tool decodes from its own first pass -- including
  while it is still reading the flight controller's configuration, which is when it has to be
  able to see the model arm.
- **A setting changed in the tool reaches it within about 30 seconds** of the tool being closed
  (the tool pauses it, above), for example switching the adjustment announcements on or off.
  Every 30 seconds it looks at the settings file and at the `reload.req` beside it, and reads
  the settings again only when one of them has moved since its last read, so a radio whose
  settings stay as they are does not pay for the read.
- **It cannot be seen from the suite if it is configured as a global function** rather than on
  the model. The radio offers no way for a script to read the global special functions, so a
  background decoder installed there is invisible to the check above.
- **It watches the dashboard widget and records the moment it stops.** A widget that uses more
  than its share of a cycle is not called again by the radio, so it cannot write down that this
  happened to it; this script runs outside the widgets and can. With the log level at *DEBUG* or
  above its log then carries a line naming how long the dashboard has been silent and what its
  last drawn cycle cost. A dashboard on another screen page or behind one of the radio's menu pages
  is still called by the radio and still does its work, so it is not reported. A model without this script has nothing
  that can report that.
- **It writes a log of its own** when *Log Session To Card* is on and the log level is *DEBUG*
  or above, the `function` files of each power-up, beside the tool's and the dashboard's. Unlike
  theirs, it needs both switches to start: *Log Session To Card* alone writes no `function` file. Once it
  has started, lowering the level again does not stop it for the rest of that session, although
  its step file is then no longer rewritten. Because this script is paused and resumed rather
  than cut off, it keeps writing where a widget that overran its instruction budget cannot, and its
  one-line step file says when it last ran. See
  [collecting logs](../troubleshooting/collecting-logs.md).
