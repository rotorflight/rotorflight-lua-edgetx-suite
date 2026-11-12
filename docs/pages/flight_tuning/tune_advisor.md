---
title: Tune Advisor
sidebar_label: Tune Advisor
sidebar_position: 30
---

# Tune Advisor

While you fly in acro mode, the flight controller measures how the heli answers the sticks. Each time you
disarm, the radio saves that flight's measurements. This page combines your last flights and suggests one change
at a time for each axis. Press *Save* in the header to write the suggested changes for the shown axis to the
flight controller, or make them yourself on *PIDs*, *Rates* or *PID Controller*. Then fly again and come back.

The flight controller counts only acro flight while spooled up and airborne, with the heli moving: a moment counts
only when the heli has turned at 40 deg/s or more, summed over the three axes, within the last 2 seconds, so calm
hovering counts nothing. Time in Angle, Horizon, Trainer, Altitude hold, Rescue, GPS rescue or failsafe is left out. A useful set is about
ten seconds of rolls, flips and pirouettes with the stick centred after each one, which one flight may or may not
give.

The page shows the flights of the PID and rate profile active on the flight controller, so that each setup gets its
own advice and *Save* writes to the profiles the flights were flown on. It combines up to the last 5 flights flown
on those profiles and on the same tune as the newest of them. Counting back from that flight, a flight on other
profiles, or one that does not say which profiles it was flown on, is passed over: it neither counts nor ends the
count, and stays saved for its own profiles. The first flight on these profiles with a different P, F, B, I-term
relax cut-off, rate type or rates on that axis ends the count, because the advice is worked out against the tune
you fly now. So does a flight with a different cyclic polarity, cyclic ring or I-term relax type, or one where any
of these three is not known. When flights on other profiles are saved too, the first line under *Why* reads
"Flights on other profiles are kept for those profiles."; with no flight on the active profiles the page says, for
example, "No flight saved on PID 2, rates 1 yet". The active profiles come from the *PID#* and *RTE#* telemetry
sensors; without them the page asks the flight controller when it opens and on *Reload*, only while disarmed
("Reading the active profiles..." meanwhile), and otherwise uses the ones the flight controller reported last. A
flight is saved under the profiles the same way: the sensors, or one request before the save without them. Under
polar cyclic, Roll flies on the Pitch rates, so for Roll a change of the Pitch rates ends the count too. Combining
flights adds up the counts and averages each measurement weighted by how much data it came from; the flight
controller weights its own figures slightly differently, so the combined response is a close estimate rather than
exact, while the stop figures combine exactly.

## How a flight is saved

After each disarm the radio reads all three axes from the flight controller, saves them as one flight, then clears
the flight controller's measurements so the next flight is measured on its own. It starts 5 seconds after the
disarm and waits 2 seconds after each answer before the next request, so telemetry sensors keep updating; the
flight is saved about 10 seconds after the disarm (2 seconds later without the *PID#* and *RTE#* sensors, when the
profiles are asked for first). Then it reads the cyclic polarity, the cyclic ring and the I-term relax type and
adds them to the saved flight, since they change what its numbers mean. A value that could not be read stays
unknown, and so do all three if you switch the PID or rate profile before they are read: the values read then would
belong to the other profile.

- **The saving is done by the RFSuite dashboard widget or the RFSuite Service widget**, whether or not this page
  is open (see [Service widget](../../dashboard/service-widget.md)). With neither of them on the model, no flight
  is saved. The configuration tool started from the radio's tool list does not save flights itself, and while it
  is open EdgeTX runs no widget, so nothing is saved until you close it.
- **The disarm is seen through the model's arming sensor** (`ARM`; `ARMF` or `STAT` also serve). A model without
  it never shows a disarm, so no flight is saved. It is there once the model's sensors have been discovered with
  the flight controller connected (the model's *Telemetry* page, *Discover new*).
- **The measurements live in the flight controller's memory until they are saved.** Unplugging the battery
  within about 10 seconds of the disarm loses that flight.
- **A link loss is caught up.** If the model is disarmed while the link is down, the flight is read once the radio
  reconnects, provided the flight controller has not been powered off in between. If the link drops the reading,
  the radio asks again 5 seconds later; after three failures it waits for the next disarm, and since the flight
  controller was not cleared, that flight is then saved together with this one. An answer for another axis than
  the one asked for is not kept; that axis is asked again, and it counts as one of those failures. If the link
  drops after the flight is saved but before the flight controller is cleared, the clear is not sent when the
  link is back: the model may have flown meanwhile, and the clear would erase that flight unread. The flight
  controller is then cleared after the next disarm, as below.
- **If another flight controller is connected before the clear**, it is not cleared, and its settings are not
  added to the first one's flight; that flight stays saved with its settings unknown.
- **Arming again before the flight is saved** stops the reading. The flight controller keeps adding to its
  measurements, so the next disarm saves both flights as one.
- **Arming again after the flight is saved but before the clear has gone through** (or after a clear lost to the
  link) leaves that flight in the flight controller, which adds the next flight to it. The radio does not send that
  old clear afterwards, since it would erase the next flight before it is read; the next disarm reads first, saves,
  and then clears. That reading still holds the earlier flight, which the radio cannot tell from the reply, so that
  flight is then counted twice.
- **The same holds while the RFSuite widgets do not run for more than 5 seconds** (the configuration tool open):
  the model may have flown meanwhile, so a clear still owed is not sent afterwards, and the flight controller is
  cleared after the next disarm.
- **A flight that cannot be written to the SD card** (the card is full or write-protected, or the history file is
  over the 16 KiB the page reads) is tried again 5 seconds later, and after three failed writes the radio waits for
  the next disarm. The flight controller is not cleared, so that disarm reads the flight again, together with the
  next one.
- A flight with no acro flight time is not saved.

**Coming from another dashboard:** put the RFSuite dashboard or the RFSuite Service widget on a screen of the model
(see [Service widget](../../dashboard/service-widget.md)) and check that the model has an arming sensor: `ARM`,
`ARMF` or `STAT`. Opening the configuration tool from the tool list after a flight shows the flights the widget saved;
it saves none itself.

With no flight saved for the connected flight controller, *Flight data* reads "No flight saved yet", *Suggested
changes* says what saves a flight and *Why* names the widgets and the `ARM` sensor. The page asks the flight
controller what it still holds when it opens, on *Reload* and when another flight controller connects; when that
answer finds measurements nobody saved, *Why* starts with how long they are, for example "The flight controller holds
1m 59s of flight that were not saved": a flight was flown and counted, and nothing on the radio saved it. After a
flight whose reading failed while the page stayed open, press *Reload* to ask again.

The flights are kept on the radio's SD card in `/SCRIPTS/RFSUITE/user/tune/<mcu id>.lua`, one line per
flight and axis, newest last; the last 5 flights of each PID and rate profile are kept, at most 20 in all (the 
profiles with the most flights give up their oldest first), and the file is kept under 15 KiB. `<mcu id>` is the flight controller's board ID,
with characters other than letters, digits, underscores and hyphens replaced by underscores, the same name as its
[change journal](../../reference/change-journal.md) in `journal/<mcu id>.lua` beside the `tune` folder. Each save
replaces the whole file, so a save that is cut short leaves the previous file in place (or as `<mcu id>.lua.bak`,
which is then read instead). A line that does not read
is skipped, and the rest of the file still counts.

## Where to find it

*Configuration* → *Flight Tuning* → *Tune Advisor*

Needs MSP API 12.10; greyed out on an older flight controller, and it cannot be opened while the model is armed.
The page and the saving both need firmware that sends the packed tune advisor reply (payload version 3, added to
the firmware by rotorflight-firmware pull request #570). A flight controller without it, or with an older reply
layout, shows "Needs newer firmware" on this page, and its flights are not saved; *Reload* asks again, and so
does connecting another flight controller while the page is open.

The page does not poll the flight controller. It reads the flights saved for the connected model when it opens
and on *Reload*, and asks the flight controller once, then, whether it has the tune advisor at all. Through a link
loss it keeps showing the flights; only a different flight controller brings up its own. With no board ID known,
it shows "Connect to a model first".

Opened from the dashboard (see [Quick menu](../../dashboard/quick-menu.md)), the page runs inside the dashboard,
which keeps saving flights meanwhile, and it reads the flights again when one is saved while it is open, once
the cyclic polarity, cyclic ring and I-term relax type have been added to it (a few seconds after the save). Until
that flight is saved it shows "Reading the last flight..." in place of the advice, with *Save* and *\** greyed
out. If the radio could not read the flight, the advice from the saved flights comes back with "Last flight not
read. It is read at the next disarm." above it; if it could not write the flight to the card, with "Last flight
not saved to the card. Check the card before the next flight; the next disarm tries again." above it.

## Settings

| Line | What it shows |
| --- | --- |
| Axis | Roll, Pitch or Yaw. Everything below is for the chosen axis. |
| Flight data | Minutes and seconds of acro flight in the flights combined, and how many of the last 5 on the active profiles that is, for example "2m 12s, 3/5 flights". "No flight saved yet" when none is saved for this flight controller (see *How a flight is saved*), "No flight saved on PID 2, rates 1 yet" when none is saved on the active profiles. |
| Profiles | The PID profile and rate profile active on the flight controller, for example "PID 1, rates 1". Only flights flown on these profiles are combined. |
| Response | How fast the heli turns compared with the rate the stick asks for, for example "53% faster than asked". "Needs more flying" shows how much data is still needed; "Too uneven to judge" means the response varies too much. |
| Stops | How much the heli bounces back after you centre the stick, as a share of the turn rate. Needs 10 stops. "Shaking 49 deg/s" instead means the heli oscillates with the stick centred (see the rules below). |
| Suggested changes | Up to three changes, each named by the page, row and column to change and in the units that page shows, for example *PIDs > Roll > FF: 100 -> 80* and *Rates > Roll > Max Rate: 720 -> 900*. When there is something *Save* can write, a last line says so. |
| Why | The reason for each change, and a fact worth knowing when there is room (for example how much faster the heli turns at high collective). |
| * (header) | Erases this model's saved flights and resets the flight controller's current measurements, after asking to confirm. The change journal is kept. |
| Save (header) | Writes the suggested changes for the shown axis to the flight controller. Available while connected and disarmed, with a known board ID, at least one change it can write and no save already running. See *Applying the changes* below. |
| Reload (header) | Reads the active profiles and the saved flights again and asks the flight controller again whether it has the tune advisor. |

**The profiles the flights were flown on.** The advice uses the cyclic polarity, cyclic ring and I-term relax type
saved with the newest flight on the active profiles. If the active profiles change while the page is open (a switch
on the transmitter, seen through the *PID#* and *RTE#* sensors), the first line under *Suggested changes* reads,
for example, "Flown on PID profile 2 and rate profile 1. Switch to them to save." and *Save* stays off: switch
back, or press *Reload* to see the flights of the new profiles.

## The rules

- **Shakes with the stick centred** (15 deg/s or more, measured over at least 5 s of centred stick): lower P by
  one step (P / 1.2), and nothing else for that axis until it is calm. An oscillation also reads as bounce-back
  after every stop and spoils the response figure, so the other rules would be misled. When P cannot be lowered,
  the reasons still name the shake. If lowering P does not calm it, check D and the linkages.
- **Turns faster or slower than asked** (more than 15% off): change FF and the rates by the same amount in
  opposite directions, so the stick feel stays the same but the heli flies the rate you ask for. One step changes
  FF by at most 20%. With Actual, Quick and Rotorflight rates the page gives the exact rate values; with
  Betaflight, Raceflight and KISS rates it gives a percentage. An axis with FF set to 0 (often the tail) gets no FF
  advice.
- **Full stick asks for more rate than the heli reaches** (roll and pitch), with the cyclic at its limit: lower
  the rates toward what the heli reaches, by at most 20% per step. What full stick asks for takes the cyclic ring
  into account: below a ring of 100% the flight controller holds one axis at full stick to the ring's share of the
  rate curve's maximum, so that, not the curve's maximum, is what the reached rate is measured against. With both
  sticks in a corner it is held lower still, which the measurements do not tell apart.
- **Stops bounce back 12% or more**: if the I-term pushes back, lower *Advanced > PID Controller > Cut-off point*
  by 20%, on an axis that I-term relax acts on. With *I-term relax* off for the axis (OFF acts on none, RP on roll
  and pitch, RPY on all three), the reasons say so and no cut-off change is suggested. If FF does not match yet,
  fix FF first. Otherwise raise P by 20% (or add B).
- **P is raised to at most 50% above your own P**, which allows two steps. Your own P is the last one you set: the
  page follows the [change journal](../../reference/change-journal.md) back through its own changes to P on that
  axis and PID profile, and stops at any other change. A P set by hand on the *PIDs* page starts the count again.
  If stops still bounce back after that, the reasons say "P is already ...% above your setting. Check the
  mechanics." More P will not fix it. With no journal yet, your current P counts as your own. A journal that is
  there but cannot be read (over 64 KiB, or it does not open) raises no P at all, and the reasons say "The change
  journal could not be read, so P is not raised."
- **A change would go past a setting's limit**: the page does not suggest it, or any change that goes with it
  (FF is never suggested without its rates). Instead, the reasons say "The change needed goes past a setting's
  limit." Look for the cause outside the tune, for example the mechanics or the head speed. For a rate the limit
  is the one the flight controller keeps for the rate type, the same the *Rates* page shows: Center Sens and Max
  Rate 2000 °/s for Actual, Max Rate 2000 °/s for Quick, Rate 1000 °/s for Rotorflight. A larger value would be cut
  back by the flight controller when it saves.

## Polar cyclic

With polar cyclic rates (*Advanced* → *Rates (Advanced)* → *Cyclic Behaviour*, *Polar coordinates*), the *Rates*
page shows one *Cyclic* row, which edits the Pitch rates. While polar is on, the flight controller applies that one
curve to the whole cyclic stick, roll included, and a rate change on that row changes both axes in flight. The
Roll rates are not changed by the row; they are kept as they were and apply again once polar is switched off.

When the newest flight was flown with polar on, on the profiles that are active now, Roll and Pitch rate
suggestions name the *Cyclic* row, work from the Pitch rates, and *Save* writes the Pitch rates for either axis. A
*Cyclic* rate write marks both Roll and Pitch as applied. FF, P and cut-off suggestions stay per axis. Roll and
Pitch are still judged separately, so their advice can ask for different changes to the one *Cyclic* row: change
it once, fly, and check both again.

## Applying the changes

*Save* first lists the changes and asks you to confirm. It then:

1. **Reads current settings**: the active profiles, PIDs, PID Controller and Rates from the flight controller. A
   failed or short read stops here and nothing is changed.
2. Checks that the flight controller still holds the tune these flights were flown with: the same PID and rate
   profile, the same P, F, B, I-term relax cut-off, rate type and rates on that axis, and the same polar cyclic
   setting (and *Cyclic* rates) the advice used. A cut-off change also needs *I-term relax* to still act on the
   axis, and a rate change needs the cyclic ring to give full stick the same rate as during the flights. If
   anything differs (you changed it by hand, switched profile, or already applied this advice), it stops with
   nothing changed: fly again on the current settings. It also stops if a new value is out of range or the heli is
   armed.
3. **Writes the changes**: only the settings that change; every other setting is written back exactly as it was
   read.
4. **Saves to the flight controller** without a reboot, so the changes survive a restart.
5. **Checks the saved settings**: reads them back and reports how many changes were written and read back, or
   names the first one that differs. If the settings cannot be read back, it says the save is unverified; if a
   profile changed during the save, it asks you to check both profiles.

With Betaflight, Raceflight or KISS rates the page can only give the rate change as a percentage, so *Save* does not
write it, and does not write the FF change that goes with it either: FF on its own would change the stick feel.
Make both changes by hand, or switch to Actual, Quick or Rotorflight rates. P and cut-off suggestions stay
writable.

If saving fails, the page says what may still be active until a restart:

- "Saving failed. The changes are active until the flight controller restarts, then undone." means the save to
  the flight controller's memory failed or timed out: the new values are active but were not stored. Restart the
  flight controller to undo them.
- "Writing failed. Nothing was saved: restart the flight controller to undo any part already sent." means a write
  failed or timed out before the save. Some values may already be active; restart the flight controller to
  restore the stored settings.

After a save, the axis shows "Changes saved to the flight controller. Fly again to check the new tune." for as long
as the page stays open. Opened again before the next flight is saved, the page shows the advice of the same
flights again, and *Save* stops with "The settings on the flight controller are not the ones these flights were
flown with": the flight controller now holds the new tune.

The saved flights are kept. The next flight is on the new tune, so the page starts again from it and leaves the
older flights out. Each value written is added to the flight controller's
[change journal](../../reference/change-journal.md), with the profile, the old and the new value, so you can see
what the advisor changed and set it back by hand. A journal failure is reported with the save result; the changes
already stored on the flight controller stay stored. *\** does not erase the journal.

## Adjustment functions

In-flight adjustments (*Setup* → *Controls* → *Adjustments*) can change the same settings the advisor measures
and writes: P, F, B, the rates and the I-term relax cut-off per axis, and the PID and rate profile. The firmware
applies an adjustment straight away and saves it when you disarm.

- **Adjusting during a flight starts the measurements again.** On firmware with rotorflight-firmware pull request
  #607, a profile switch, or an adjustment that changes a P, I, D, F, B or O gain, a rate or an expo, makes the
  flight controller drop everything it has measured so far and start again on the new tune. That flight is then
  saved with only the part flown after the last change; a change shortly before landing leaves too little, or
  nothing, and a flight with no acro flight time is not saved. A flight not saved yet (see *How a flight is saved*)
  is dropped with it. Leave these adjustments alone while collecting flights for the advisor.
- **On older firmware, adjusting during a flight mixes two tunes.** On a 4.7 development build from before that
  pull request the flight controller checks the tune only when you arm, so a flight where you adjusted one of
  these settings (or switched profile) is measured partly on the old value and saved as if flown on the value you
  ended on. If you did use one, press *\** and fly again.
- **Adjusting between flights is fine.** A *STEPPED* adjustment is saved at disarm, so the next flight is on a new
  tune and the advisor starts again from it, as it does after *Save*.
- **A *MAPPED* adjustment overrides Save.** It sets the value from the channel's position: once the knob moves,
  and at every power-up while its range is enabled, the value goes back to what the knob says. A value written by
  *Save* then lasts only until that happens. Before applying advice to a setting, set its adjustment's *Type* to
  *OFF*, or leave the knob where it gives the new value.
- *Save* checks the profiles and values at the moment it writes, so an adjustment or profile switch made since the
  flights stops it with nothing changed.

## Related

- [PIDs](pids.md)
- [Rates](rates.md)
- [PID Controller](advanced/pid_controller.md)
- [Cyclic Behaviour](advanced/rates_advanced/cyclic_behaviour.md)
- [Adjustments](../setup/controls/adjustments.md)
- [Service widget](../../dashboard/service-widget.md)
- [Change journal](../../reference/change-journal.md)
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
